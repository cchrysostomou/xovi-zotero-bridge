$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root "xovi\appload\zotero-library"
$outputDirectory = Join-Path $root "dist"
$buildDirectory = Join-Path $outputDirectory "appload-build"
$output = Join-Path $outputDirectory "xovi-zotero-appload-app.zip"
$resources = Join-Path $buildDirectory "resources.rcc"

foreach ($required in @("manifest.json", "icon.png", "application.qrc", "ui\ZoteroLibrary.qml")) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $required))) {
        throw "Missing AppLoad source file: $required"
    }
}

New-Item -ItemType Directory -Force -Path $outputDirectory, $buildDirectory | Out-Null

function Invoke-NativeRcc([string]$Qrc, [string]$Destination) {
    $rcc = Get-Command rcc -ErrorAction SilentlyContinue
    if (-not $rcc) { $rcc = Get-Command rcc6 -ErrorAction SilentlyContinue }
    if (-not $rcc) { $rcc = Get-Command qt6-rcc -ErrorAction SilentlyContinue }
    if (-not $rcc) { return $false }
    & $rcc.Source --binary -o $Destination $Qrc
    if ($LASTEXITCODE -ne 0) { throw "rcc failed while building AppLoad resources." }
    return $true
}

function Invoke-WslRcc([string]$Qrc, [string]$Destination) {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { return $false }
    function Convert-ToWslPath([string]$Path) {
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full -notmatch '^([A-Za-z]):\\(.*)$') {
            throw "Only absolute Windows paths can be converted for WSL rcc: $Path"
        }
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2].Replace('\', '/')
        return "/mnt/$drive/$rest"
    }
    $qrcWsl = Convert-ToWslPath $Qrc
    $destinationWsl = Convert-ToWslPath $Destination
    $script = Join-Path $buildDirectory "build-rcc.sh"
    $scriptText = @'
#!/usr/bin/env bash
set -eu

qrc=$1
destination=$2
cache="${HOME}/.cache/xovi-zotero-bridge/rcc"
marker="${cache}/.ready"

mkdir -p "${cache}"
cd "${cache}"
if [[ ! -f "${marker}" ]]; then
    rm -rf extracted
    mkdir -p extracted
    apt-get download \
        qt6-base-dev-tools libqt6core6t64 libdouble-conversion3 libb2-1 \
        libglib2.0-0t64 libicu78 libpcre2-16-0 zlib1g libgomp1 >/dev/null
    for deb in *.deb; do
        dpkg-deb -x "${deb}" extracted
    done
    LD_LIBRARY_PATH="${cache}/extracted/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}" \
        "${cache}/extracted/usr/lib/qt6/libexec/rcc" -v >/dev/null
    touch "${marker}"
fi

LD_LIBRARY_PATH="${cache}/extracted/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}" \
    "${cache}/extracted/usr/lib/qt6/libexec/rcc" --binary -o "${destination}" "${qrc}"
'@
    [System.IO.File]::WriteAllText(
        $script, $scriptText.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    $scriptWsl = Convert-ToWslPath $script
    & wsl bash $scriptWsl $qrcWsl $destinationWsl
    if ($LASTEXITCODE -ne 0) { throw "WSL rcc failed while building AppLoad resources." }
    return $true
}

$qrc = Join-Path $source "application.qrc"
if (-not (Invoke-NativeRcc $qrc $resources)) {
    if (-not (Invoke-WslRcc $qrc $resources)) {
        throw "Required command not found: rcc. Install Qt rcc or WSL with apt-get download support."
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Leaf)) {
    throw "AppLoad resources.rcc was not created."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($output, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive(
    $stream, [System.IO.Compression.ZipArchiveMode]::Create)
$encoding = New-Object System.Text.UTF8Encoding($false)
try {
    $files = @(
        @{ Path = (Join-Path $source "manifest.json"); Name = "zotero-library/manifest.json"; Binary = $false; Mode = 33188 }
        @{ Path = (Join-Path $source "icon.png"); Name = "zotero-library/icon.png"; Binary = $true; Mode = 33188 }
        @{ Path = $resources; Name = "zotero-library/resources.rcc"; Binary = $true; Mode = 33188 }
    )
    foreach ($file in $files) {
        $entry = $zip.CreateEntry($file.Name, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.ExternalAttributes = $file.Mode -shl 16
        $destination = $entry.Open()
        try {
            if ($file.Binary) {
                $bytes = [System.IO.File]::ReadAllBytes($file.Path)
            } else {
                $text = [System.IO.File]::ReadAllText($file.Path).Replace("`r`n", "`n")
                $bytes = $encoding.GetBytes($text)
            }
            $destination.Write($bytes, 0, $bytes.Length)
        } finally {
            $destination.Dispose()
        }
    }
} finally {
    $zip.Dispose()
    $stream.Dispose()
}

Write-Output "Created $output"
Write-Output "Contains the AppLoad Zotero Library app. It reuses zotbridge-run.sh list/tags/import/status instead of shipping a separate backend."
