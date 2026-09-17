#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CURL="${ZOTBRIDGE_CURL:-curl}"
if ! command -v "$CURL" >/dev/null 2>&1; then
    if [ -x /home/root/.vellum/bin/curl ]; then
        CURL=/home/root/.vellum/bin/curl
    else
        printf '%s\n' 'ERROR: curl is required.' >&2
        exit 1
    fi
fi

check_access() {
    label="$1"
    file="$2"
    expected="$3"
    if [ ! -r "$file" ]; then
        printf 'FAIL: %s: missing private connection file.\n' "$label" >&2
        return 1
    fi
    if code="$("$CURL" --disable --config "$file" --silent \
        --connect-timeout 10 --max-time 30 --output /dev/null \
        --write-out '%{http_code}' 2>/dev/null)"; then
        if [ "$code" = "$expected" ]; then
            printf 'PASS: %s (HTTP %s)\n' "$label" "$code"
        else
            printf 'FAIL: %s returned HTTP %s; expected %s. Check credentials, permissions and URL.\n' \
                "$label" "$code" "$expected" >&2
            return 1
        fi
    else
        result=$?
        case "$result" in
            5|6) detail='DNS resolution failed' ;;
            7) detail='server connection failed' ;;
            28) detail='request timed out' ;;
            35|51|58|60|77) detail='TLS/certificate validation failed' ;;
            *) detail='network or curl configuration failure' ;;
        esac
        printf 'FAIL: %s: %s (curl exit %s).\n' "$label" "$detail" "$result" >&2
        return 1
    fi
}

failed=0
check_access 'Zotero metadata access' "$ROOT/zotero.curl" 200 || failed=1
check_access 'WebDAV directory access' "$ROOT/webdav.curl" 207 || failed=1
printf '%s\n' 'Read-only access check only: no PDF validation, imports or remote changes.'
exit "$failed"
