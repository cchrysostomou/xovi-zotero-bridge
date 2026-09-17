<#
.SYNOPSIS
Updates the xovi-zotero-bridge runtime and 3.28 QMD patches on a reMarkable.

.EXAMPLE
.\scripts\update-remarkable.ps1

.EXAMPLE
.\scripts\update-remarkable.ps1 -TargetHost 192.168.1.33 -User root
#>
[CmdletBinding()]
param(
    [string]$TargetHost = "192.168.1.33",
    [string]$User = "root",
    [string]$BridgeDirectory = "/home/root/xovi-zotero-bridge",
    [string]$QmdDirectory = "/home/root/xovi/exthome/qt-resource-rebuilder",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $Name"
    }
}

$root = Split-Path -Parent $PSScriptRoot
$tabletPackage = Join-Path $root "dist\xovi-zotero-library-aarch64.zip"
$qmdPackage = Join-Path $root "dist\xovi-zotero-quick-settings-qmd.zip"

Require-Command ssh
Require-Command scp
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "package-tablet.ps1")
    & (Join-Path $PSScriptRoot "package-xovi-quick-settings.ps1")
}
foreach ($package in @($tabletPackage, $qmdPackage)) {
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        throw "Missing package: $package. Run the package scripts or omit -SkipBuild."
    }
}

$destination = "$User@$TargetHost"
$remoteStaging = "/tmp/zotbridge-update-$PID"
$remoteScript = Join-Path ([System.IO.Path]::GetTempPath()) "zotbridge-update-$PID.sh"
$remoteScriptContent = @'
#!/bin/sh
set -eu

stage=$1
bridge=$2
qmd=$3

cleanup() {
    rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

test -d "$bridge"
test -d "$qmd"
test -f "$stage/xovi-zotero-library-aarch64.zip"
test -f "$stage/xovi-zotero-quick-settings-qmd.zip"
command -v unzip >/dev/null

# The runtime archive deliberately contains no config.toml or bridge state.
unzip -oq "$stage/xovi-zotero-library-aarch64.zip" -d "$bridge"
unzip -oq "$stage/xovi-zotero-quick-settings-qmd.zip" -d "$stage/qmd"
chmod 755 "$bridge/bin/jq" "$bridge/bin/rmapi" "$bridge/bin/7zz" "$bridge/scripts/"*.sh

test -s "$stage/qmd/3.28/zoteroQuickSync.qmd"
test -s "$stage/qmd/3.28/zoteroBridgeSettings.qmd"
cp "$stage/qmd/3.28/zoteroQuickSync.qmd" "$qmd/zoteroQuickSync.qmd"
cp "$stage/qmd/3.28/zoteroBridgeSettings.qmd" "$qmd/zoteroBridgeSettings.qmd"

test -x "$bridge/bin/jq"
test -x "$bridge/bin/rmapi"
test -x "$bridge/bin/7zz"
test -x "$bridge/scripts/zotbridge-run.sh"
test -s "$qmd/zoteroQuickSync.qmd"
test -s "$qmd/zoteroBridgeSettings.qmd"
printf '%s\n' "Updated Zotero Bridge runtime and 3.28 QMD patches."
'@

try {
    [System.IO.File]::WriteAllText(
        $remoteScript, $remoteScriptContent.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    & ssh $destination "mkdir -p '$remoteStaging'"
    if ($LASTEXITCODE -ne 0) { throw "Could not create remote staging directory." }

    & scp $tabletPackage $qmdPackage $remoteScript "${destination}:${remoteStaging}/"
    if ($LASTEXITCODE -ne 0) { throw "Package transfer failed." }

    & ssh $destination "sh '$remoteStaging/zotbridge-update-$PID.sh' '$remoteStaging' '$BridgeDirectory' '$QmdDirectory'"
    if ($LASTEXITCODE -ne 0) { throw "Remote update failed; existing config.toml and bridge state were not targeted." }
} finally {
    if (Test-Path -LiteralPath $remoteScript) {
        Remove-Item -LiteralPath $remoteScript -Force
    }
}

Write-Output "Update complete. Restart XOVI using your normal procedure to load the QMD changes."
