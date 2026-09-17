#!/bin/sh
set -eu
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CURL="${ZOTBRIDGE_CURL:-curl}"
if ! command -v "$CURL" >/dev/null 2>&1; then
    CURL=/home/root/.vellum/bin/curl
fi
for tool in "$CURL" unzip dd wc mktemp rm rmdir; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'FAIL: required tool unavailable: %s\n' "$tool" >&2
        exit 1
    fi
done

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
unzip_help="$(unzip -h 2>&1 || :)"
case "$unzip_help" in
    *BusyBox*) set -- -p ;;
    *UnZip*|*Info-ZIP*) set -- -p -P '' ;;
    *) fail 'Unsupported unzip implementation; expected BusyBox or Info-ZIP.' ;;
esac
IFS= read -r member < "$ROOT/member.txt" || fail 'Missing ZIP member selection.'
IFS= read -r expected < "$ROOT/expected-size.txt" || fail 'Missing expected PDF size.'
case "$expected" in
    ''|*[!0-9]*) fail 'Invalid expected PDF size.' ;;
esac
[ "$expected" -gt 0 ] && [ "$expected" -le 2147483648 ] || fail 'Expected PDF size is out of range.'

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zotbridge-pdf.XXXXXX")"
cleanup() {
    rm -f "$WORK/download.zip" "$WORK/document.pdf" "$WORK/errors"
    rmdir "$WORK"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if code="$("$CURL" --disable --config "$ROOT/webdav-pdf.curl" --silent \
    --connect-timeout 10 --max-time 60 --output "$WORK/download.zip" \
    --write-out '%{http_code}' 2>"$WORK/errors")"; then
    [ "$code" = 200 ] || fail "WebDAV returned HTTP $code; no PDF accepted."
else
    result=$?
    fail "WebDAV download failed (curl exit $result). Check connectivity, TLS and file availability."
fi
printf '%s\n' 'PASS: WebDAV ZIP downloaded (HTTP 200)'

# sh implementations use either 512- or 1024-byte ulimit blocks; bound output
# close to the known PDF size, then require the exact expected byte count below.
if (ulimit -f "$(( (expected + 511) / 512 + 1 ))" &&
    unzip "$@" "$WORK/download.zip" "$member" < /dev/null > "$WORK/document.pdf" 2>"$WORK/errors"); then
    :
else
    result=$?
    fail "ZIP extraction/CRC check failed or exceeded the output bound (exit $result)."
fi
if signature="$(dd bs=5 count=1 < "$WORK/document.pdf" 2>"$WORK/errors")"; then
    [ "$signature" = '%PDF-' ] || fail 'Downloaded member is not a PDF.'
else
    fail 'Could not read the downloaded PDF header.'
fi
actual="$(wc -c < "$WORK/document.pdf")"
[ "$actual" -eq "$expected" ] || fail 'PDF size differs from the prepared sample; regenerate the probe.'
printf 'PASS: PDF extracted and validated (%s bytes)\n' "$expected"
printf '%s\n' 'Temporary files removed on exit. No reMarkable import or remote changes.'
