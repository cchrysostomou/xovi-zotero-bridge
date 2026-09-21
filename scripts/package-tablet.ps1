param([switch]$DependenciesOnly)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"
$downloads = Join-Path $dist "downloads"
New-Item -ItemType Directory -Force -Path $downloads | Out-Null

$version = "jq-1.8.2"
$expectedHash = "8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"
$jq = Join-Path $downloads "jq-linux-arm64"
if (-not (Test-Path -LiteralPath $jq)) {
    Invoke-WebRequest -UseBasicParsing `
        "https://github.com/jqlang/jq/releases/download/$version/jq-linux-arm64" -OutFile $jq
}
if ((Get-FileHash -LiteralPath $jq -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw "Downloaded jq checksum does not match the pinned official release. Remove dist\downloads\jq-linux-arm64 and retry."
}

$rmapiVersion = "v0.0.35"
$rmapiArchiveHash = "645c170d8119b4dcb652cf79612e362fcb032dc0e5869ff520eec1324da39637"
$rmapiBinaryHash = "544da553a210051e5d0ade2bd24d16c30fa6fa7236215b460c6b7f6d62ec3029"
$rmapiArchive = Join-Path $downloads "rmapi-linux-arm64-$rmapiVersion.tar.gz"
$rmapiDirectory = Join-Path $downloads "rmapi-$rmapiVersion-arm64"
$rmapi = Join-Path $rmapiDirectory "rmapi"
if (-not (Test-Path -LiteralPath $rmapiArchive)) {
    Invoke-WebRequest -UseBasicParsing `
        "https://github.com/ddvk/rmapi/releases/download/$rmapiVersion/rmapi-linux-arm64.tar.gz" `
        -OutFile $rmapiArchive
}
if ((Get-FileHash -LiteralPath $rmapiArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rmapiArchiveHash) {
    throw "Downloaded rmapi archive checksum does not match the pinned official release."
}
if (-not (Test-Path -LiteralPath $rmapi)) {
    New-Item -ItemType Directory -Force -Path $rmapiDirectory | Out-Null
    & tar -xzf $rmapiArchive -C $rmapiDirectory
    if ($LASTEXITCODE -ne 0) { throw "Could not extract the pinned rmapi archive." }
}
if ((Get-FileHash -LiteralPath $rmapi -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rmapiBinaryHash) {
    throw "Extracted rmapi binary checksum does not match the pinned release."
}

$sevenZipVersion = "26.03"
$sevenZipArchiveHash = "2389ba20e4d8295e8709c20b6263b69bd1ec4972fe38a04ad7a1badbf595b996"
$sevenZipBinaryHash = "9a26e7d54bfdae8a8f1750cdb70697547b738c2334aa89f3d3f2c8645c8443fe"
$sevenZipArchive = Join-Path $downloads "7z2603-linux-arm64.tar.xz"
$sevenZipDirectory = Join-Path $downloads "7z2603-arm64"
$sevenZip = Join-Path $sevenZipDirectory "7zz"
if (-not (Test-Path -LiteralPath $sevenZipArchive)) {
    Invoke-WebRequest -UseBasicParsing `
        "https://github.com/ip7z/7zip/releases/download/$sevenZipVersion/7z2603-linux-arm64.tar.xz" `
        -OutFile $sevenZipArchive
}
if ((Get-FileHash -LiteralPath $sevenZipArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sevenZipArchiveHash) {
    throw "Downloaded 7-Zip archive checksum does not match the pinned official release."
}
if (-not (Test-Path -LiteralPath $sevenZip)) {
    New-Item -ItemType Directory -Force -Path $sevenZipDirectory | Out-Null
    & tar -xf $sevenZipArchive -C $sevenZipDirectory
    if ($LASTEXITCODE -ne 0) { throw "Could not extract the pinned 7-Zip archive." }
}
if ((Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sevenZipBinaryHash) {
    throw "Extracted 7zz binary checksum does not match the pinned release."
}

$licenses = @{
    "jq-COPYING" = "https://raw.githubusercontent.com/jqlang/jq/$version/COPYING"
    "oniguruma-COPYING" = "https://raw.githubusercontent.com/kkos/oniguruma/4ef89209a239c1aea328cf13c05a2807e5c146d1/COPYING"
    "musl-COPYRIGHT" = "https://git.musl-libc.org/cgit/musl/plain/COPYRIGHT?h=v1.2.5"
    "rmapi-AGPL-3.0.txt" = "https://raw.githubusercontent.com/ddvk/rmapi/$rmapiVersion/LICENSE"
    "7zip-License.txt" = "https://raw.githubusercontent.com/ip7z/7zip/$sevenZipVersion/DOC/License.txt"
}
foreach ($name in $licenses.Keys) {
    Invoke-WebRequest -UseBasicParsing $licenses[$name] -OutFile (Join-Path $downloads $name)
}
if ($DependenciesOnly) {
    Write-Output "Verified $version ARM64 binary and downloaded redistribution notices."
    exit 0
}

$runtimeFiles = @("zotbridge-run.sh", "zotbridge-shell.sh", "zotbridge-shell-config.jq", "zotbridge-shell-mapping.jq", "zotbridge-shell-zip.jq", "zotbridge-shell-sync.sh", "zotbridge-shell-reverse.sh", "zotbridge-shell-settings.jq")
foreach ($required in $runtimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $required))) {
        throw "Missing shell backend file: $required"
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$output = Join-Path $dist "xovi-zotero-library-aarch64.zip"
$stream = [System.IO.File]::Open($output, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
$encoding = New-Object System.Text.UTF8Encoding($false)
try {
    $files = @(
        @{ Path = (Join-Path $root "README.md"); Name = "README.md"; Binary = $false }
        @{ Path = (Join-Path $root "config.example.toml"); Name = "config.example.toml"; Binary = $false }
        @{ Path = $jq; Name = "bin/jq"; Binary = $true }
        @{ Path = $rmapi; Name = "bin/rmapi"; Binary = $true }
        @{ Path = $sevenZip; Name = "bin/7zz"; Binary = $true }
        @{ Path = (Join-Path $root "xovi\assets\zotero-send-icon.png"); Name = "assets/zotero-send-icon.png"; Binary = $true }
    )
    foreach ($file in $runtimeFiles) {
        $files += @{ Path = (Join-Path $PSScriptRoot $file); Name = "scripts/" + $file; Binary = $false }
    }
    foreach ($name in $licenses.Keys) {
        $files += @{ Path = (Join-Path $downloads $name); Name = "licenses/" + $name; Binary = $false }
    }
    foreach ($file in $files) {
        $entry = $zip.CreateEntry($file.Name, [System.IO.Compression.CompressionLevel]::Optimal)
        $mode = 33188 # Regular file, 0644.
        if ($file.Name -in @("bin/jq", "bin/rmapi", "bin/7zz") -or $file.Name.EndsWith(".sh")) { $mode = 33261 } # 0755.
        $entry.ExternalAttributes = $mode -shl 16
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
Write-Output "Tags reuse the JSON cache until --refresh; existing config and state are not packaged."
Write-Output "Contains Zotero commands plus verified ARM64 jq and rmapi; excludes credentials, cloud tokens, state, private probes and Python."
