[CmdletBinding(DefaultParameterSetName = "Local")]
param(
    [Parameter(ParameterSetName = "Local")]
    [switch]$Local,
    [Parameter(Mandatory = $true, ParameterSetName = "Release")]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Commit
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$version = "0.1.0"
$work = Join-Path $root "dist\vellum"
$recipeDirectory = Join-Path $work "packages\zotero-remarkable-sync"
if ($Commit) {
    $head = & git -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -ne $Commit) { throw "Check out the requested release commit before building." }
    $changes = & git -C $root status --porcelain
    if ($LASTEXITCODE -ne 0 -or $changes) { throw "Release builds require a clean working tree." }
}
$project = [IO.File]::ReadAllText((Join-Path $root "pyproject.toml"))
if ($project -notmatch "(?m)^version = `"$([regex]::Escape($version))`"\r?$") {
    throw "Project version does not match Vellum version $version."
}
foreach ($script in @("package-tablet.ps1", "package-xovi-appload.ps1", "package-xovi-quick-settings.ps1")) {
    & (Join-Path $PSScriptRoot $script)
    if (-not $?) { throw "$script failed." }
}
New-Item -ItemType Directory -Force -Path $recipeDirectory | Out-Null
$sevenZipSource = Join-Path $root "dist\downloads\7zip-26.03-source.tar.gz"
if (-not (Test-Path -LiteralPath $sevenZipSource)) {
    Invoke-WebRequest -UseBasicParsing "https://github.com/ip7z/7zip/archive/refs/tags/26.03.tar.gz" -OutFile $sevenZipSource
}
if ((Get-FileHash -LiteralPath $sevenZipSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne
    "74b11efd8559f9b3dc652e89dc8ebdf4acb66e514a745e44cf75582cdf4512fd") {
    throw "7-Zip source checksum mismatch."
}
function Convert-ToWslPath([string]$Path) {
    $converted = & wsl -d Ubuntu --exec wslpath -a $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) { throw "Cannot convert WSL path: $Path" }
    return $converted.Trim()
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stage = Join-Path $work ("stage-" + [guid]::NewGuid().ToString("N"))
$bridge = Join-Path $stage "home\root\xovi-zotero-bridge"
$appLoad = Join-Path $stage "home\root\xovi\exthome\appload"
$qmd = Join-Path $stage "home\root\xovi\exthome\qt-resource-rebuilder"
$licenses = Join-Path $stage "home\root\.vellum\licenses\zotero-remarkable-sync"
try {
    New-Item -ItemType Directory -Force -Path $bridge, $appLoad, $qmd, $licenses | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $root "dist\xovi-zotero-library-aarch64.zip"), $bridge)
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $root "dist\xovi-zotero-appload-app.zip"), $appLoad)
    foreach ($patch in @("zoteroQuickSync", "zoteroBridgeSettings", "zoteroSendToZotero")) {
        $text = [IO.File]::ReadAllText((Join-Path $root "xovi\3.28\$patch.qmd")).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $qmd "$patch.qmd"), $text, [Text.UTF8Encoding]::new($false))
    }
    Copy-Item -LiteralPath (Join-Path $bridge "LICENSE") -Destination $licenses
    Copy-Item -Path (Join-Path $bridge "licenses\*") -Destination $licenses
    $assembly = Join-Path $work "assemble.sh"
    [IO.File]::WriteAllText($assembly,
        [IO.File]::ReadAllText((Join-Path $root "packaging\vellum\assemble.sh")).Replace("`r`n", "`n"),
        [Text.UTF8Encoding]::new($false))
    $sourceCommit = "local"
    if ($Commit) { $sourceCommit = $Commit }
    & wsl -d Ubuntu --exec bash (Convert-ToWslPath $assembly) (Convert-ToWslPath $root) `
        (Convert-ToWslPath $stage) (Convert-ToWslPath $work) $sourceCommit $version
    if ($LASTEXITCODE -ne 0) { throw "Vellum payload assembly failed." }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
$archiveName = "xovi-zotero-bridge-$version-aarch64.tar.gz"
$archive = Join-Path $work $archiveName
& (Join-Path $PSScriptRoot "verify-vellum-package.ps1") -Archive $archive
$checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant()
$source = "https://github.com/cchrysostomou/xovi-zotero-bridge/releases/download/v$version/$archiveName"
if (-not $Commit) {
    $source = $archiveName
    Copy-Item -LiteralPath $archive -Destination (Join-Path $recipeDirectory $archiveName) -Force
}
$recipe = [IO.File]::ReadAllText((Join-Path $root "packaging\vellum\zotero-remarkable-sync\VELBUILD.in"))
$recipe = $recipe.Replace("@COMMIT@", $sourceCommit).Replace("@SOURCE@", $source).Replace("@CHECKSUM@", $checksum)
if (-not $Commit) { $recipe = $recipe -replace '(?m)^readmeurl=.*\r?\n', '' }
[IO.File]::WriteAllText((Join-Path $recipeDirectory "VELBUILD"), $recipe.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Created $(Join-Path $recipeDirectory 'VELBUILD')"
if (-not $Commit) { Write-Warning "LOCAL TEST ONLY: do not publish or submit this recipe." }
