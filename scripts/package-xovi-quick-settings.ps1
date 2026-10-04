$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root "xovi"
$outputDirectory = Join-Path $root "dist"
$output = Join-Path $outputDirectory "xovi-zotero-quick-settings-qmd.zip"
$files = @(
    @{ Path = (Join-Path $source "README.md"); Name = "README.md" }
    @{ Path = (Join-Path $source "3.27\zoteroQuickSync.qmd"); Name = "3.27/zoteroQuickSync.qmd" }
    @{ Path = (Join-Path $source "3.28\zoteroQuickSync.qmd"); Name = "3.28/zoteroQuickSync.qmd" }
    @{ Path = (Join-Path $source "3.28\zoteroBridgeSettings.qmd"); Name = "3.28/zoteroBridgeSettings.qmd" }
    @{ Path = (Join-Path $source "3.28\zoteroSendToZotero.qmd"); Name = "3.28/zoteroSendToZotero.qmd" }
)

foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file.Path)) {
        throw "Missing Quick Settings UI file: $($file.Path)"
    }
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($output, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive(
    $stream, [System.IO.Compression.ZipArchiveMode]::Create)
$encoding = New-Object System.Text.UTF8Encoding($false)
try {
    foreach ($file in $files) {
        $entry = $zip.CreateEntry($file.Name, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.ExternalAttributes = 33188 -shl 16 # Regular file, 0644.
        $destination = $entry.Open()
        try {
            $text = [System.IO.File]::ReadAllText($file.Path).Replace("`r`n", "`n")
            $bytes = $encoding.GetBytes($text)
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
Write-Output "Contains only firmware-specific QMLDiff patches and installation instructions; no config, state, credentials, backend runtime, or AppLoad app."
