#!/usr/bin/env bash
set -euo pipefail

root=$1
stage=$2
output=$3
commit=$4
version=$5
export PATH="$HOME/localbin/go/bin:$PATH"
command -v go >/dev/null || { echo "Go is required to prepare corresponding source." >&2; exit 1; }

work=$(mktemp -d)
trap 'chmod -R u+w -- "$work"; rm -rf -- "$work"' EXIT
mkdir "$work/payload"
cp -R "$stage/." "$work/payload/"
stage="$work/payload"
licenses="$stage/home/root/.vellum/licenses/zotero-remarkable-sync"
helper="$work/helper"
mkdir -p "$licenses" "$helper"
cp -R "$root/tools/rmapi-fork/." "$helper/"
(
    cd "$helper"
    go mod vendor
    freetype=$(go list -mod=mod -m -f '{{.Dir}}' github.com/golang/freetype)
    cp -R "$freetype/licenses" vendor/github.com/golang/freetype/
    chmod -R u+w vendor/github.com/golang/freetype/licenses
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -mod=vendor -trimpath \
        -o "$stage/home/root/xovi-zotero-bridge/bin/zotbridge-localgeta" ./cmd/zotbridge-localgeta
    go version > BUILD-INFO
    printf '%s\n' 'CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -mod=vendor -trimpath -o zotbridge-localgeta ./cmd/zotbridge-localgeta' >> BUILD-INFO
)
tar -czf "$licenses/helper-source.tar.gz" -C "$helper" .
cp "$root/dist/downloads/7zip-26.03-source.tar.gz" "$licenses/"
(
    cd "$licenses"
    printf 'App source: https://github.com/cchrysostomou/xovi-zotero-bridge/tree/%s\n' "$commit"
    printf '%s\n' \
        'helper-source.tar.gz contains the modified AGPL helper, vendored Go dependencies and build instructions.' \
        'Freetype-Go is redistributed under its GPL-2.0-or-later option, choosing GPLv3 for compatibility with AGPLv3.' \
        'Go toolchain source: https://go.dev/dl/' \
        '7-Zip source: https://github.com/ip7z/7zip/archive/refs/tags/26.03.tar.gz' \
        '7-Zip binary: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-linux-arm64.tar.xz' \
        'jq source: https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-1.8.2.tar.gz' \
        'jq binary: https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-arm64' \
        'Oniguruma source: https://github.com/kkos/oniguruma/tree/4ef89209a239c1aea328cf13c05a2807e5c146d1' \
        'musl source: https://musl.libc.org/releases/musl-1.2.5.tar.gz' \
        '7zz dynamically uses firmware glibc, libstdc++ and libgcc; these libraries are not bundled.'
    sha512sum helper-source.tar.gz 7zip-26.03-source.tar.gz
    (cd "$stage/home/root/xovi-zotero-bridge" && sha512sum bin/*)
) > "$licenses/SOURCES"

find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod 755 "$stage/home/root/xovi-zotero-bridge/bin/"*
chmod 755 "$stage/home/root/xovi-zotero-bridge/scripts/"*.sh
archive="$output/xovi-zotero-bridge-$version-aarch64.tar.gz"
tar --owner=0 --group=0 --numeric-owner -czf "$archive" -C "$stage" home
printf 'Created %s\n' "$archive"
