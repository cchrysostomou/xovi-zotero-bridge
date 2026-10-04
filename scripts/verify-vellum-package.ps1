param([Parameter(Mandatory = $true)][string]$Archive)
$ErrorActionPreference = "Stop"
$names = & tar -tzf $Archive
if ($LASTEXITCODE -ne 0) { throw "Cannot read Vellum payload." }
$runtime = "home/root/xovi-zotero-bridge"
$licenses = "home/root/.vellum/licenses/zotero-remarkable-sync"
$expected = @(
    "$runtime/LICENSE", "$runtime/README.md", "$runtime/config.example.toml",
    "$runtime/bin/jq", "$runtime/bin/7zz", "$runtime/bin/zotbridge-localgeta",
    "$runtime/assets/zotero-send-icon.png",
    "home/root/xovi/exthome/appload/zotero-library/LICENSE",
    "home/root/xovi/exthome/appload/zotero-library/manifest.json",
    "home/root/xovi/exthome/appload/zotero-library/resources.rcc",
    "home/root/xovi/exthome/appload/zotero-library/icon.png",
    "$licenses/LICENSE", "$licenses/SOURCES", "$licenses/helper-source.tar.gz",
    "$licenses/7zip-26.03-source.tar.gz"
)
foreach ($script in @("zotbridge-run.sh", "zotbridge-shell.sh", "zotbridge-shell-config.jq",
        "zotbridge-shell-mapping.jq", "zotbridge-shell-zip.jq", "zotbridge-shell-sync.sh",
        "zotbridge-shell-reverse.sh", "zotbridge-shell-settings.jq")) {
    $expected += "$runtime/scripts/$script"
}
foreach ($patch in @("zoteroQuickSync", "zoteroBridgeSettings", "zoteroSendToZotero")) {
    $expected += "home/root/xovi/exthome/qt-resource-rebuilder/$patch.qmd"
}
foreach ($notice in @("jq-COPYING", "oniguruma-COPYING", "musl-COPYRIGHT",
        "7zip-License.txt", "rmapi-AGPL-3.0.txt", "zotbridge-localgeta-NOTICE.txt")) {
    $expected += "$runtime/licenses/$notice", "$licenses/$notice"
}
$actual = @($names | Where-Object { -not $_.EndsWith("/") })
if ($actual.Count -ne $expected.Count -or (Compare-Object $expected $actual)) {
    throw "Vellum payload does not match the exact allowed file list."
}
$listing = & tar -tvzf $Archive
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect Vellum payload permissions." }
foreach ($line in $listing) {
    $mode = $line.Substring(0, 10)
    if ($mode -notin @("drwxr-xr-x", "-rw-r--r--", "-rwxr-xr-x")) {
        throw "Unsafe archive entry: $line"
    }
    if ($line -match '/(bin/[^/]+|scripts/[^/]+\.sh)$' -and $mode -ne "-rwxr-xr-x") {
        throw "Runtime is not executable: $line"
    }
}
Write-Output "PASS: exact $($expected.Count)-file payload; safe permissions; no personal configuration, state or PDFs."
