# Builds zotbridge-localgeta (the local, cloud-free reMarkable annotation
# merge tool in tools/rmapi-fork) for the tablet's linux/arm64 target.
#
# Requires a Go 1.23+ toolchain reachable from WSL, either on PATH or at
# ~/localbin/go/bin/go. Cross-compilation to arm64 works from any host
# arch since the tool is pure Go (no cgo).

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$forkDir = Join-Path $root "tools\rmapi-fork"
$dist = Join-Path $root "dist"
$downloads = Join-Path $dist "downloads"
New-Item -ItemType Directory -Force -Path $downloads | Out-Null

if (-not (Test-Path -LiteralPath $forkDir)) {
    throw "Missing tools\rmapi-fork; cannot build zotbridge-localgeta."
}

function Convert-ToWslPath([string]$WindowsPath) {
    $result = wsl -e wslpath -a $WindowsPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
        throw "Could not convert '$WindowsPath' to a WSL path. Is WSL installed?"
    }
    return $result.Trim()
}

$forkWslPath = Convert-ToWslPath $forkDir
$outputWindows = Join-Path $downloads "zotbridge-localgeta"
$outputWsl = Convert-ToWslPath $outputWindows

$buildScript = @"
set -e
if command -v go >/dev/null 2>&1; then
    GOBIN_DIR=""
elif [ -x "`$HOME/localbin/go/bin/go" ]; then
    export PATH="`$HOME/localbin/go/bin:`$PATH"
else
    echo 'error: no Go toolchain found on PATH or at ~/localbin/go/bin/go inside WSL.' >&2
    echo 'Install Go 1.23+ in WSL, e.g.:' >&2
    echo '  curl -sL -o /tmp/go.tar.gz https://dl.google.com/go/go1.23.4.linux-amd64.tar.gz' >&2
    echo '  mkdir -p `$HOME/localbin && tar -C `$HOME/localbin -xzf /tmp/go.tar.gz' >&2
    exit 1
fi
cd '$forkWslPath'
GOOS=linux GOARCH=arm64 go build -o '$outputWsl' ./cmd/zotbridge-localgeta
"@
$buildScriptPath = Join-Path $downloads "build-zotbridge-localgeta.sh"
[System.IO.File]::WriteAllText($buildScriptPath, $buildScript.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
$buildScriptWsl = Convert-ToWslPath $buildScriptPath

& wsl -e bash $buildScriptWsl
if ($LASTEXITCODE -ne 0) { throw "Building zotbridge-localgeta failed." }
Remove-Item -LiteralPath $buildScriptPath -Force

if (-not (Test-Path -LiteralPath $outputWindows)) {
    throw "Build did not produce $outputWindows."
}

Write-Output "Built $outputWindows"
