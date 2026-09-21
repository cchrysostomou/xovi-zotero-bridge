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
    [string]$AppLoadDirectory = "/home/root/xovi/exthome/appload",
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
$appLoadPackage = Join-Path $root "dist\xovi-zotero-appload-app.zip"

Require-Command ssh
Require-Command scp
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "package-tablet.ps1")
    & (Join-Path $PSScriptRoot "package-xovi-quick-settings.ps1")
    & (Join-Path $PSScriptRoot "package-xovi-appload.ps1")
}
foreach ($package in @($tabletPackage, $qmdPackage, $appLoadPackage)) {
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
appload=$4

cleanup() {
    rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

test -d "$bridge"
test -d "$qmd"
mkdir -p "$appload"
test -f "$stage/xovi-zotero-library-aarch64.zip"
test -f "$stage/xovi-zotero-quick-settings-qmd.zip"
test -f "$stage/xovi-zotero-appload-app.zip"
command -v unzip >/dev/null

# The runtime archive deliberately contains no config.toml or bridge state.
unzip -oq "$stage/xovi-zotero-library-aarch64.zip" -d "$bridge"
unzip -oq "$stage/xovi-zotero-quick-settings-qmd.zip" -d "$stage/qmd"
rm -rf "$stage/appload"
mkdir -p "$stage/appload"
unzip -oq "$stage/xovi-zotero-appload-app.zip" -d "$stage/appload"
chmod 755 "$bridge/bin/jq" "$bridge/bin/rmapi" "$bridge/bin/7zz" "$bridge/scripts/"*.sh

test -s "$stage/qmd/3.28/zoteroQuickSync.qmd"
test -s "$stage/qmd/3.28/zoteroBridgeSettings.qmd"
test -s "$stage/qmd/3.28/zoteroSendToZotero.qmd"
test -s "$stage/appload/zotero-library/manifest.json"
test -s "$stage/appload/zotero-library/resources.rcc"
test -s "$stage/appload/zotero-library/icon.png"
cp "$stage/qmd/3.28/zoteroQuickSync.qmd" "$qmd/zoteroQuickSync.qmd"
cp "$stage/qmd/3.28/zoteroBridgeSettings.qmd" "$qmd/zoteroBridgeSettings.qmd"
cp "$stage/qmd/3.28/zoteroSendToZotero.qmd" "$qmd/zoteroSendToZotero.qmd"
rm -rf "$appload/zotero-library"
mkdir -p "$appload"
cp -R "$stage/appload/zotero-library" "$appload/zotero-library"

test -x "$bridge/bin/jq"
test -x "$bridge/bin/rmapi"
test -x "$bridge/bin/7zz"
test -x "$bridge/scripts/zotbridge-run.sh"
test -s "$qmd/zoteroQuickSync.qmd"
test -s "$qmd/zoteroBridgeSettings.qmd"
test -s "$qmd/zoteroSendToZotero.qmd"
test -s "$appload/zotero-library/manifest.json"
test -s "$appload/zotero-library/resources.rcc"
printf '%s\n' "Updated Zotero Bridge runtime, 3.28 QMD patches and AppLoad Zotero Library app."
'@

try {
    [System.IO.File]::WriteAllText(
        $remoteScript, $remoteScriptContent.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    & ssh $destination "mkdir -p '$remoteStaging'"
    if ($LASTEXITCODE -ne 0) { throw "Could not create remote staging directory." }

    & scp $tabletPackage $qmdPackage $appLoadPackage $remoteScript "${destination}:${remoteStaging}/"
    if ($LASTEXITCODE -ne 0) { throw "Package transfer failed." }

    & ssh $destination "sh '$remoteStaging/zotbridge-update-$PID.sh' '$remoteStaging' '$BridgeDirectory' '$QmdDirectory' '$AppLoadDirectory'"
    if ($LASTEXITCODE -ne 0) { throw "Remote update failed; existing config.toml and bridge state were not targeted." }
} finally {
    if (Test-Path -LiteralPath $remoteScript) {
        Remove-Item -LiteralPath $remoteScript -Force
    }
}

Write-Output "Update complete. Restart XOVI using your normal procedure to load the QMD changes and AppLoad's app list."
