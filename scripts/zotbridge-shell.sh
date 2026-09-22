#!/usr/bin/env bash
# On-demand backend. No config is evaluated as shell code. Secret-bearing curl
# options live only in private files; curl diagnostics are never forwarded.
set -Eeuo pipefail
set +x
umask 077
ulimit -c 0
export LC_ALL=C
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Full reMarkable browsing is deferred. Gate it before
# loading configuration, inspecting state, creating files, or contacting a broker.
case "${1:-}" in
    library)
        printf '%s\n' '{"ok":false,"error":"not_implemented","message":"reMarkable library browsing is deferred; imports use the configured default_target_folder."}'
        exit 1
        ;;
esac
JQ=
WORK=
WORKER=
WORKER_IS_COMMAND=false
STATE_STAGE=
ACTIVITY_LOG=
ACTIVITY_READY=false
ACTIVITY_LOGGED=false
LOCALGETA=
SEVEN_ZIP=

activity_event() {
    local event=$1 error=${2:-} tag=${3:-} count=${4:-} item=${5:-${ITEM_KEY:-}}
    local filename=${6:-} line= action=${ZOTBRIDGE_ACTIVITY_PARENT_ACTION:-$COMMAND}
    [[ $ACTIVITY_READY == true && $COMMAND != activity-log && $COMMAND != clear-activity-log &&
       (${ZOTBRIDGE_ACTIVITY_CHILD:-false} != true || $event == hit || $event == failed) ]] || return 0
    command -v flock >/dev/null && command -v mv >/dev/null && command -v tail >/dev/null ||
        return 0
    (
        exec {activity_lock}>>"$ACTIVITY_LOG.lock"
        flock -n "$activity_lock" || exit 0
        [[ ! -L $ACTIVITY_LOG ]] || exit 0
        if [[ -e $ACTIVITY_LOG && ! -f $ACTIVITY_LOG ]]; then exit 0; fi
        line="$("$JQ" -cn --arg action "$action" --arg event "$event" --arg error "$error" \
          --arg item "$item" --arg filename "$filename" --arg tag "$tag" --arg count "$count" '
          {timestamp:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),action:$action,event:$event}
          + (if $error=="" then {} else {error:$error} end)
          + (if $item=="" then {} else {item_key:$item} end)
          + (if $filename=="" then {} else {filename:$filename} end)
          + (if $tag=="" then {} else {tag:$tag} end)
          + (if $count=="" then {} else {count:($count|tonumber)} end)')"
        if [[ -e $ACTIVITY_LOG ]] && (( $(wc -l <"$ACTIVITY_LOG") >= 200 )); then
            stage="$ACTIVITY_LOG.new.$$.$RANDOM"
            tail -n 199 "$ACTIVITY_LOG" >"$stage"
            printf '%s\n' "$line" >>"$stage"
            mv -f -- "$stage" "$ACTIVITY_LOG"
        else
            printf '%s\n' "$line" >>"$ACTIVITY_LOG"
        fi
    ) || :
}

fail() {
    activity_event failed "$1" "${QUEUE_TAG:-}" "" "${ITEM_KEY:-}" "${ZOTERO_FILENAME:-}"
    ACTIVITY_LOGGED=true
    if [[ -n $JQ ]]; then
        "$JQ" -cn --arg error "$1" --arg message "$2" '{ok:false,error:$error,message:$message}'
    else
        printf '%s\n' '{"ok":false,"error":"missing_dependency","message":"A working jq is required. Install the bundled bin/jq for this CPU or install jq on PATH."}'
    fi
    exit 1
}
cleanup() {
    local status=$?
    trap - EXIT ERR HUP INT TERM
    if [[ $ACTIVITY_LOGGED == false ]]; then
        if ((status == 0)); then activity_event completed "" "${QUEUE_TAG:-}"
        else activity_event failed nonzero_exit "${QUEUE_TAG:-}"
        fi
    fi
    if [[ -n $WORKER ]]; then
        if [[ $WORKER_IS_COMMAND == true ]]; then
            kill -TERM "$WORKER" 2>/dev/null || :
            for ((cleanup_tick=0; cleanup_tick<300; cleanup_tick++)); do
                kill -0 "$WORKER" 2>/dev/null || break
                sleep 0.01
            done
        fi
        kill -KILL "$WORKER" 2>/dev/null || :
        wait "$WORKER" 2>/dev/null || :
    fi
    [[ -z $STATE_STAGE ]] || rm -f -- "$STATE_STAGE"
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    :
}
trap cleanup EXIT
trap 'fail interrupted "Operation interrupted; check status before retrying an import."' HUP INT TERM
trap 'fail runtime_error "Operation failed. Check dependencies, file permissions and available disk space."' ERR

if [[ -n ${ZOTBRIDGE_JQ:-} ]]; then
    [[ -x $ZOTBRIDGE_JQ ]] && "$ZOTBRIDGE_JQ" -n 'true' >/dev/null 2>&1 ||
        fail missing_dependency ""
    JQ=$ZOTBRIDGE_JQ
elif [[ -x $ROOT_DIR/bin/jq ]] && "$ROOT_DIR/bin/jq" -n 'true' >/dev/null 2>&1; then
    JQ="$ROOT_DIR/bin/jq"
elif command -v jq >/dev/null 2>&1 && jq -n 'true' >/dev/null 2>&1; then
    JQ="$(command -v jq)"
else
    fail missing_dependency ""
fi
# Suppress raw errors: remote URLs, metadata and configuration values may be private.
exec 2>/dev/null
for dependency in wc mkdir chmod rm dirname; do
    command -v "$dependency" >/dev/null || fail missing_dependency "Required utility missing: $dependency."
done
if [[ -n ${ZOTBRIDGE_CURL:-} ]]; then
    [[ -x $ZOTBRIDGE_CURL ]] ||
        fail missing_dependency "ZOTBRIDGE_CURL must name an executable curl binary."
    CURL=$ZOTBRIDGE_CURL
elif [[ -x /home/root/.vellum/bin/curl ]]; then
    CURL=/home/root/.vellum/bin/curl
else
    CURL="$(command -v curl)" || fail missing_dependency "Install curl (including TLS support), or make /home/root/.vellum/bin/curl executable."
fi

if [[ ${1:-} == --help || ${1:-} == -h || $# == 0 ]]; then
    printf '%s\n' 'Usage: zotbridge-run.sh list [--query TEXT] [--tag NAME ...] [--collection KEY] [--limit 1..100] [--skip N] [--json] [--page-info]' \
      '       zotbridge-run.sh tags [--query TEXT] [--json] [--refresh]' \
      '       zotbridge-run.sh collections [--json] [--refresh]' \
      '       zotbridge-run.sh clear-mappings' \
      '       zotbridge-run.sh settings [--json]' \
      '       zotbridge-run.sh settings-apply' \
      '       zotbridge-run.sh activity-log' \
      '       zotbridge-run.sh clear-activity-log' \
      '       zotbridge-run.sh children --item-key KEY [--json]' \
      '       zotbridge-run.sh import --item-key KEY [--attachment-key KEY] [--target-folder PATH] [--retry-uncertain] [--include-zotero-tags] [--add-unread-tag]' \
      '       zotbridge-run.sh sync-tagged [--tag to_sync] [--synced-tag synced] [--target-folder PATH]' \
      '       zotbridge-run.sh reverse-sync' \
      '       zotbridge-run.sh sync-all' \
      '       zotbridge-run.sh sync-item --item-key KEY [--tag to_sync] [--synced-tag synced] [--target-folder PATH]' \
      '       zotbridge-run.sh status --item-key KEY' \
      '       zotbridge-run.sh ensure-folder --target-folder PATH' \
      '       zotbridge-run.sh check-connection [--webdav] [--item-key KEY]' \
      '       zotbridge-run.sh doc-status --uuid RM_UUID' \
      '       zotbridge-run.sh doc-tags --uuid RM_UUID' \
      '       zotbridge-run.sh queue-for-zotero --uuid RM_UUID --mode new|attach [--parent-key KEY] [--collection KEY] [--tags a,b,c] [--annotated-only]'
    exit 0
fi
COMMAND=$1
shift
QUERY= LIMIT= LIMIT_GIVEN=false SKIP=0 AS_JSON=false PAGE_INFO=false ITEM_KEY= TARGET= RETRY=false
TARGET_GIVEN=false
REFRESH=false
COLLECTION=
QUEUE_TAG=
SYNCED_TAG=
QUEUE_TAG_SET=false
SYNCED_TAG_SET=false
ATTACHMENT_KEY_OPT=
INCLUDE_ZOTERO_TAGS=false
ADD_UNREAD_TAG=false
TAGS=()
UUID_OPT=
QUEUE_MODE=
QUEUE_PARENT_KEY=
QUEUE_TAGS_RAW=
QUEUE_TAGS=()
QUEUE_ANNOTATED_ONLY=false
while (($#)); do
    case "$1" in
        --query|-q) [[ $COMMAND =~ ^(list|tags)$ && $# -ge 2 ]] || fail ValueError "Invalid --query option."; QUERY=$2; shift 2 ;;
        --limit|-n) [[ $COMMAND == list && $# -ge 2 ]] || fail ValueError "Invalid --limit option."; LIMIT=$2; LIMIT_GIVEN=true; shift 2 ;;
        --skip|--start) [[ $COMMAND == list && $# -ge 2 ]] || fail ValueError "Invalid --skip option."; SKIP=$2; shift 2 ;;
        --tag|-t)
            [[ $COMMAND =~ ^(list|sync-tagged|sync-item)$ && $# -ge 2 ]] || fail ValueError "Invalid --tag option."
            if [[ $COMMAND == list ]]; then TAGS+=("$2"); else QUEUE_TAG=$2; QUEUE_TAG_SET=true; fi
            shift 2 ;;
        --collection|-c) [[ $COMMAND =~ ^(list|queue-for-zotero)$ && $# -ge 2 ]] || fail ValueError "Invalid --collection option."; COLLECTION=$2; shift 2 ;;
        --synced-tag) [[ $COMMAND =~ ^sync-(tagged|item)$ && $# -ge 2 ]] || fail ValueError "Invalid --synced-tag option."; SYNCED_TAG=$2; SYNCED_TAG_SET=true; shift 2 ;;
        --page-info) [[ $COMMAND == list ]] || fail ValueError "Invalid --page-info option."; PAGE_INFO=true; shift ;;
        --json) [[ $COMMAND =~ ^(list|tags|collections|settings|children)$ ]] || fail ValueError "Invalid --json option."; AS_JSON=true; shift ;;
        --refresh) [[ $COMMAND =~ ^(tags|collections)$ ]] || fail ValueError "--refresh is only supported by tags and collections."; REFRESH=true; shift ;;
        --item-key) [[ $COMMAND =~ ^(import|status|check-connection|sync-item|children)$ && $# -ge 2 ]] || fail ValueError "Invalid --item-key option."; ITEM_KEY=$2; shift 2 ;;
        --attachment-key) [[ $COMMAND == import && $# -ge 2 ]] || fail ValueError "Invalid --attachment-key option."; ATTACHMENT_KEY_OPT=$2; shift 2 ;;
        --target-folder) [[ $COMMAND =~ ^(import|ensure-folder|sync-tagged|sync-item)$ && $# -ge 2 ]] || fail ValueError "Invalid --target-folder option."; TARGET=$2; TARGET_GIVEN=true; shift 2 ;;
        --webdav) [[ $COMMAND == check-connection ]] || fail ValueError "Invalid --webdav option."; CHECK_WEBDAV=true; shift ;;
        --retry-uncertain) [[ $COMMAND == import ]] || fail ValueError "Invalid --retry-uncertain option."; RETRY=true; shift ;;
        --include-zotero-tags) [[ $COMMAND == import ]] || fail ValueError "Invalid --include-zotero-tags option."; INCLUDE_ZOTERO_TAGS=true; shift ;;
        --add-unread-tag) [[ $COMMAND == import ]] || fail ValueError "Invalid --add-unread-tag option."; ADD_UNREAD_TAG=true; shift ;;
        --uuid) [[ $COMMAND =~ ^(doc-status|doc-tags|queue-for-zotero)$ && $# -ge 2 ]] || fail ValueError "Invalid --uuid option."; UUID_OPT=$2; shift 2 ;;
        --mode) [[ $COMMAND == queue-for-zotero && $# -ge 2 ]] || fail ValueError "Invalid --mode option."; QUEUE_MODE=$2; shift 2 ;;
        --parent-key) [[ $COMMAND == queue-for-zotero && $# -ge 2 ]] || fail ValueError "Invalid --parent-key option."; QUEUE_PARENT_KEY=$2; shift 2 ;;
        --tags) [[ $COMMAND == queue-for-zotero && $# -ge 2 ]] || fail ValueError "Invalid --tags option."; QUEUE_TAGS_RAW=$2; shift 2 ;;
        --annotated-only) [[ $COMMAND == queue-for-zotero ]] || fail ValueError "Invalid --annotated-only option."; QUEUE_ANNOTATED_ONLY=true; shift ;;
        *) fail ValueError "Unknown command option. Use --help." ;;
    esac
done
[[ $COMMAND =~ ^(list|tags|collections|clear-mappings|settings|settings-apply|activity-log|clear-activity-log|check-connection|ensure-folder|import|status|library|sync-tagged|sync-item|reverse-sync|sync-all|children|doc-status|doc-tags|queue-for-zotero)$ ]] || fail ValueError "Unknown command. Use --help."
if [[ $COMMAND == tags || $COMMAND == collections || $COMMAND == clear-mappings ]]; then
    for dependency in flock mv; do
        command -v "$dependency" >/dev/null || fail missing_dependency "JSON state operations require utility: $dependency."
    done
fi
if [[ $COMMAND == ensure-folder || $COMMAND == import || $COMMAND == sync-* || $COMMAND == reverse-sync ]]; then
    [[ $COMMAND != ensure-folder || $TARGET_GIVEN == true ]] || fail ValueError "ensure-folder requires --target-folder PATH."
    for dependency in stat flock mv sleep; do
        command -v "$dependency" >/dev/null || fail missing_dependency "Folder operations require utility: $dependency."
    done
    sleep 0.01 || fail missing_dependency "Folder operations require sleep with fractional-second support."
fi
if [[ $LIMIT_GIVEN == true ]]; then
    [[ $LIMIT =~ ^[0-9]{1,3}$ ]] && ((10#$LIMIT >= 1 && 10#$LIMIT <= 100)) || fail ValueError "limit must be from 1 to 100."
    LIMIT=$((10#$LIMIT))
fi
[[ $SKIP =~ ^[0-9]{1,10}$ ]] && ((10#$SKIP <= 2147483647)) ||
    fail ValueError "skip must be from 0 to 2147483647."
SKIP=$((10#$SKIP))
if [[ -n $ITEM_KEY || $COMMAND == import || $COMMAND == status || $COMMAND == sync-item || $COMMAND == children ]]; then
    [[ $ITEM_KEY =~ ^[A-Z0-9]{8}$ ]] || fail ValueError "item-key must contain exactly eight uppercase letters or digits."
fi
[[ -z $ATTACHMENT_KEY_OPT ]] || [[ $ATTACHMENT_KEY_OPT =~ ^[A-Z0-9]{8}$ ]] ||
    fail ValueError "attachment-key must contain exactly eight uppercase letters or digits."
[[ -z $COLLECTION ]] || [[ $COLLECTION =~ ^[A-Z0-9]{8}$ ]] ||
    fail ValueError "collection must contain exactly eight uppercase letters or digits."
if [[ $COMMAND =~ ^(doc-status|doc-tags|queue-for-zotero)$ ]]; then
    [[ $UUID_OPT =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
        fail ValueError "uuid must be a canonical reMarkable document UUID."
    UUID_OPT=${UUID_OPT,,}
fi
if [[ $COMMAND == queue-for-zotero ]]; then
    [[ $QUEUE_MODE =~ ^(new|attach)$ ]] ||
        fail ValueError "mode must be new or attach."
    if [[ $QUEUE_MODE == attach ]]; then
        [[ $QUEUE_PARENT_KEY =~ ^[A-Z0-9]{8}$ ]] || fail ValueError "attach mode requires --parent-key KEY."
    else
        [[ -z $QUEUE_PARENT_KEY ]] || fail ValueError "--parent-key is only valid with --mode attach."
    fi
    [[ -z $COLLECTION || $QUEUE_MODE == new ]] ||
        fail ValueError "--collection is only valid with --mode new."
    if [[ -n $QUEUE_TAGS_RAW ]]; then
        [[ $QUEUE_TAGS_RAW != ,* && $QUEUE_TAGS_RAW != *, && $QUEUE_TAGS_RAW != *,,* ]] ||
            fail ValueError "tags must be a comma-separated list of nonempty tags without control characters."
        IFS=',' read -r -a QUEUE_TAGS <<<"$QUEUE_TAGS_RAW"
        "$JQ" -ne --args '$ARGS.positional | length>0 and all(.[];
          length>0 and (contains(",")|not) and (test("[\u0000-\u001f\u007f]")|not))' \
          -- "${QUEUE_TAGS[@]}" >/dev/null ||
            fail ValueError "tags must be a comma-separated list of nonempty tags without control characters."
    fi
    for dependency in flock find md5sum sha256sum cut tr cp grep mv; do
        command -v "$dependency" >/dev/null || fail missing_dependency "Sending a document to Zotero requires utility: $dependency."
    done
fi
if [[ $COMMAND == import || $COMMAND == sync-* || ($COMMAND == check-connection && -n $ITEM_KEY) ]]; then
    for dependency in unzip dd mv; do
        command -v "$dependency" >/dev/null || fail missing_dependency "PDF operations require utility: $dependency."
    done
fi

CONFIG="${ZOTBRIDGE_CONFIG:-$ROOT_DIR/config.toml}"
[[ $CONFIG != "~/"* ]] || CONFIG="$HOME/${CONFIG:2}"
[[ -f $CONFIG ]] || fail FileNotFoundError "Missing configuration. Copy config.example.toml to config.toml and configure it."
CONFIG_DIR="$(CDPATH= cd -- "$(dirname -- "$CONFIG")" && pwd)"
[[ $CONFIG == /* ]] || CONFIG="$PWD/$CONFIG"
WORK_BASE="${ZOTBRIDGE_WORK_DIR:-$ROOT_DIR}"
[[ -d $WORK_BASE ]] || fail configuration_error "ZOTBRIDGE_WORK_DIR must be an existing writable directory."
WORK_BASE="$(CDPATH= cd -- "$WORK_BASE" && pwd)"
for ((attempt=0; attempt<10; attempt++)); do
    candidate="$WORK_BASE/.zotbridge-work.$$.$RANDOM"
    if mkdir -m 700 -- "$candidate"; then WORK=$candidate; break; fi
done
[[ -n $WORK ]] || fail runtime_error "Cannot create a private working directory."
"$JQ" -Rse -f "$ROOT_DIR/scripts/zotbridge-shell-config.jq" "$CONFIG" >"$WORK/config.json" ||
    fail configuration_error "Invalid configuration. Shell backend supports flat keys with JSON-compatible quoted strings, numbers and booleans; no tables, literal/multiline strings or duplicate keys. Check required values and limits."
get_config() { "$JQ" -r ".$1" "$WORK/config.json"; }
[[ $TARGET_GIVEN == true ]] || TARGET="$(get_config default_target_folder)"
[[ $LIMIT_GIVEN == true ]] || LIMIT="$(get_config list_page_limit)"
[[ $QUEUE_TAG_SET == true ]] || QUEUE_TAG="$(get_config sync_queue_tag)"
[[ $SYNCED_TAG_SET == true ]] || SYNCED_TAG="$(get_config sync_synced_tag)"
absolute_path() {
    case "$1" in
        "~/"*) REPLY="$HOME/${1:2}" ;;
        /*) REPLY=$1 ;;
        *) REPLY="$CONFIG_DIR/$1" ;;
    esac
}
absolute_path "$(get_config state_json_path)"; STATE=$REPLY
absolute_path "$(get_config state_db_path)"; SQLITE_STATE=$REPLY
[[ $STATE != "$SQLITE_STATE" ]] || fail configuration_error "state_json_path must differ from state_db_path; SQLite files are never migrated or overwritten."
ACTIVITY_LOG="$STATE.activity.jsonl"
[[ ! -L $ACTIVITY_LOG ]] || fail activity_log_error "Activity log must not be a symbolic link."
[[ ! -e $ACTIVITY_LOG || -f $ACTIVITY_LOG ]] ||
    fail activity_log_error "Activity log must be a regular file."
mkdir -p -- "$(dirname -- "$ACTIVITY_LOG")" ||
    fail activity_log_error "Cannot create the activity log directory."
ACTIVITY_READY=true
[[ $COMMAND =~ ^(sync-tagged|reverse-sync|sync-all)$ ]] || activity_event started
if [[ -n ${ZOTBRIDGE_LOCALGETA:-} ]]; then
    [[ -x $ZOTBRIDGE_LOCALGETA ]] || fail missing_dependency "ZOTBRIDGE_LOCALGETA must name an executable zotbridge-localgeta binary."
    LOCALGETA=$ZOTBRIDGE_LOCALGETA
elif [[ -x $ROOT_DIR/bin/zotbridge-localgeta ]]; then
    LOCALGETA="$ROOT_DIR/bin/zotbridge-localgeta"
fi
if [[ -n ${ZOTBRIDGE_7ZZ:-} ]]; then
    [[ -x $ZOTBRIDGE_7ZZ ]] || fail missing_dependency "ZOTBRIDGE_7ZZ must name an executable 7zz binary."
    SEVEN_ZIP=$ZOTBRIDGE_7ZZ
elif [[ -x $ROOT_DIR/bin/7zz ]]; then
    SEVEN_ZIP="$ROOT_DIR/bin/7zz"
fi
absolute_path "$(get_config mb_in_path)"; MB_IN=$REPLY
absolute_path "$(get_config mb_out_path)"; MB_OUT=$REPLY
absolute_path "$(get_config xochitl_dir)"; LIBRARY=$REPLY
USE_WEBDAV="$(get_config use_webdav)"
LIBRARY_TYPE="$(get_config library_type)"
LIBRARY_ID="$(get_config library_id)"
API="https://api.zotero.org/${LIBRARY_TYPE}s/$LIBRARY_ID"
LIBRARY_SCOPE="$LIBRARY_TYPE:$LIBRARY_ID"
BROKER_TIMEOUT="$(get_config broker_timeout_s)"
ZOTERO_TIMEOUT="$(get_config zotero_timeout_s)"
WEBDAV_TIMEOUT="$(get_config webdav_timeout_s)"
MAX_BYTES=$(($(get_config zotero_max_download_mb) * 1024 * 1024))
[[ $USE_WEBDAV != true ]] || MAX_BYTES=$(($(get_config webdav_max_download_mb) * 1024 * 1024))

lock_state() {
    mkdir -p -- "$(dirname -- "$STATE")"
    exec {json_lock}>>"$STATE.lock"
    flock -n "$json_lock" || fail busy "Another operation is using this JSON state; try later."
}
load_state() {
    [[ ! -L $STATE ]] || fail state_error "JSON state must not be a symbolic link."
    if [[ -e $STATE ]]; then
        [[ -f $STATE ]] || fail state_error "JSON state must be a regular file."
        "$JQ" -se '
          def cache_valid:
            type=="object" and all(.[];
              type=="object" and all(.[];
                type=="object"
                and (.fetched_at | type=="number" and .>=0 and floor==.)
                and (.tags | type=="array" and all(.[]; type=="string") and .==unique)));
          def collection_cache_valid:
            type=="object" and all(.[];
              type=="object"
              and (.fetched_at | type=="number" and .>=0 and floor==.)
              and (.collections | type=="array" and all(.[];
                type=="object" and (.key|type=="string") and (.name|type=="string"))));
          length==1 and (.[0] | type=="object" and .version==1
            and (.mappings|type=="object") and (.attempts|type=="object")
            and (if has("tag_cache") then (.tag_cache|cache_valid) else true end)
            and (if has("collection_cache") then (.collection_cache|collection_cache_valid) else true end))' "$STATE" >/dev/null ||
            fail state_error "Invalid JSON state. Existing SQLite state is separate and is not automatically migrated."
        "$JQ" '.tag_cache //= {} | .collection_cache //= {}' "$STATE" >"$WORK/state.json"
    else
        printf '%s\n' '{"version":1,"mappings":{},"attempts":{},"tag_cache":{},"collection_cache":{}}' >"$WORK/state.json"
    fi
}
save_state() {
    # Staging in the destination directory keeps rename atomic across filesystems.
    local candidate attempt
    for ((attempt=0; attempt<10; attempt++)); do
        candidate="$STATE.new.$$.$RANDOM"
        if (set -o noclobber; : >"$candidate"); then STATE_STAGE=$candidate; break; fi
    done
    [[ -n $STATE_STAGE ]] || fail state_error "Cannot stage JSON state."
    "$JQ" '.' "$WORK/state-next.json" >"$STATE_STAGE"
    mv -f -- "$STATE_STAGE" "$STATE"
    STATE_STAGE=
    mv -f -- "$WORK/state-next.json" "$WORK/state.json"
}
state_record() {
    "$JQ" -L "$ROOT_DIR/scripts" --arg item "$ITEM_KEY" --arg attachment "$ATTACHMENT" \
      --arg path "$TARGET" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
      --arg uuid "${DOCUMENT_UUID:-}" --arg kind "$1" '
      include "zotbridge-shell-mapping";
      if $kind=="attempt" then record_attempt($type; $library; $item; $attachment; $path)
      elif $kind=="mapping" then record_mapping($type; $library; $item; $attachment; $path; $uuid)
      else error("unknown record kind") end' \
      "$WORK/state.json" >"$WORK/state-next.json" ||
      fail state_error "Cannot record the import: invalid, conflicting or legacy mapping data."
    save_state
}
find_mapping() {
    "$JQ" -L "$ROOT_DIR/scripts" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
      --arg item "${1:-$ITEM_KEY}" 'include "zotbridge-shell-mapping";
      mapping_for_item($type; $library; $item)' "$WORK/state.json" >"$WORK/mapping.json" ||
      fail state_error "Cannot look up the import: conflicting or legacy mapping data requires explicit migration."
}
clear_state_mappings() {
    local cleared
    lock_state
    load_state
    "$JQ" -L "$ROOT_DIR/scripts" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
      'include "zotbridge-shell-mapping"; clear_mappings($type; $library)' \
      "$WORK/state.json" >"$WORK/state-next.json" ||
      fail state_error "Cannot clear mappings: invalid document mapping data."
    cleared="$("$JQ" -n --slurpfile before "$WORK/state.json" --slurpfile after "$WORK/state-next.json" \
      '($before[0].mappings|length)-($after[0].mappings|length)')"
    if ((cleared > 0)); then save_state; fi
    exec {json_lock}>&-
    "$JQ" -cn --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" --argjson cleared "$cleared" \
      '{ok:true,library_type:$type,library_id:$library,cleared:$cleared}'
}
print_activity_log() {
    if [[ ! -e $ACTIVITY_LOG ]]; then
        printf '%s\n' '{"ok":true,"entries":[]}'
        return
    fi
    "$JQ" -se '. as $entries |
      (all(.[]; type=="object" and (.timestamp|type=="string")
        and (.action|type=="string") and (.event|IN("started","found","hit","downloaded","completed","failed"))
        and (if has("item_key") then .item_key|type=="string" else true end)
        and (if has("filename") then .filename|type=="string" else true end)
        and (if has("tag") then .tag|type=="string" else true end)
        and (if has("count") then .count|type=="number" and .>=0 and floor==. else true end)
        and (if has("rm_uuid") then .rm_uuid|type=="string" else true end)
        and (if has("stage") then .stage|type=="string" else true end)
        and (if has("retained_in_source") then .retained_in_source|type=="boolean" else true end))) as $valid |
      if $valid then {ok:true,entries:$entries} else error("invalid activity log") end' \
      "$ACTIVITY_LOG" ||
      fail activity_log_error "Activity log is invalid; clear it before relying on its contents."
}
clear_activity_log() {
    local cleared=0
    command -v flock >/dev/null ||
        fail missing_dependency "Clearing the activity log requires utility: flock."
    exec {activity_lock}>>"$ACTIVITY_LOG.lock"
    flock -n "$activity_lock" || fail busy "Another operation is using the activity log; try later."
    if [[ -e $ACTIVITY_LOG ]]; then
        cleared="$(wc -l <"$ACTIVITY_LOG")"
        : >"$ACTIVITY_LOG" || fail activity_log_error "Cannot clear the activity log."
    fi
    exec {activity_lock}>&-
    ACTIVITY_LOGGED=true
    "$JQ" -cn --argjson cleared "$cleared" '{ok:true,cleared:$cleared}'
}
show_settings() {
    "$JQ" --arg mode public --argjson draft '[]' -cf "$ROOT_DIR/scripts/zotbridge-shell-settings.jq" "$WORK/config.json"
}
apply_settings() {
    local draft="$CONFIG_DIR/.zotbridge-settings-draft.json" stage=
    [[ ! -L $CONFIG && ! -L $draft ]] || fail settings_error "Configuration and settings draft must not be symbolic links."
    [[ -f $draft ]] || fail FileNotFoundError "Missing settings draft. Save settings from the Settings page first."
    "$JQ" -se 'if length==1 and (.[0]|type=="object") then .[0]
      else error("invalid draft") end' "$draft" >"$WORK/settings-draft.json" ||
      fail settings_error "Settings draft must contain one JSON object."
    exec {config_lock}>>"$CONFIG.lock"
    flock -n "$config_lock" || fail busy "Another operation is updating configuration; try later."
    "$JQ" --arg mode apply --slurpfile draft "$WORK/settings-draft.json" -f "$ROOT_DIR/scripts/zotbridge-shell-settings.jq" \
      "$WORK/config.json" >"$WORK/config-next.json" ||
      fail settings_error "Invalid settings draft. WebDAV must use HTTPS; tags and folder path must be valid."
    "$JQ" --arg mode toml --argjson draft '[]' -rf "$ROOT_DIR/scripts/zotbridge-shell-settings.jq" "$WORK/config-next.json" >"$WORK/config-next.toml" ||
      fail settings_error "Cannot render updated configuration."
    stage="$CONFIG.new.$$.$RANDOM"
    (set -o noclobber; : >"$stage") || fail settings_error "Cannot stage updated configuration."
    chmod 600 "$stage"
    cat "$WORK/config-next.toml" >"$stage" || fail settings_error "Cannot write updated configuration."
    mv -f -- "$stage" "$CONFIG"
    rm -f -- "$draft"
    exec {config_lock}>&-
    ACTIVITY_LOGGED=true
    "$JQ" --arg mode public --argjson draft '[]' -cf "$ROOT_DIR/scripts/zotbridge-shell-settings.jq" "$WORK/config-next.json" |
      "$JQ" -c '. + {applied:true}'
}

# Bash's file-size resource limit is enforced even for chunked HTTP responses or
# a ZIP whose declared size lies. No unbounded stream is buffered in memory.
limited_command() {
    local bytes=$1 output=$2
    shift 2
    (ulimit -f "$(((bytes + 1023) / 1024))"; ulimit -t 300; exec "$@") >"$output" 2>/dev/null &
    WORKER=$!
    local result=0
    wait "$WORKER" || result=$?
    WORKER=
    ((result == 0)) || return 1
    [[ $(wc -c < "$output") -le $bytes ]]
}
request() {
    local auth=$1 url=$2 output=$3 bytes=$4 seconds=$5
    local method=${6:-GET} body=${7:-} version=${8:-}
    # @json escaping is also curl config quoted-string escaping for this subset.
    printf '%s' "$url" >"$WORK/url"
    "$JQ" -nr --rawfile url "$WORK/url" --arg auth "$auth" --argjson seconds "$seconds" \
      --argjson bytes "$bytes" --arg method "$method" --arg body "$body" --arg version "$version" \
      --slurpfile cfg "$WORK/config.json" '
      "url = \($url|@json)",
      "silent", "request = \($method|@json)", "proto = \"=http,https\"", "max-redirs = 0",
      "connect-timeout = \($seconds)", "max-time = \($seconds)",
      "max-filesize = \($bytes)",
      (if $auth=="zotero" then
         "header = \(("Zotero-API-Key: "+$cfg[0].api_key)|@json)",
         "header = \"Zotero-API-Version: 3\""
       elif $auth=="webdav" then
         "user = \(($cfg[0].webdav_username+":"+$cfg[0].webdav_password)|@json)",
         "basic"
       else empty end),
      (if $method=="PATCH" then
         "header = \"Content-Type: application/json\"",
         "header = \(("If-Unmodified-Since-Version: "+$version)|@json)",
         "data-binary = \(("@"+$body)|@json)"
       elif $method=="PROPFIND" then "header = \"Depth: 0\""
       else empty end)' >"$WORK/curl.conf"
    chmod 600 "$WORK/curl.conf"
    # -q MUST be first: ignore ~/.curlrc (which could enable redirects or logging).
    limited_command "$bytes" "$WORK/http-code" "$CURL" -q --config "$WORK/curl.conf" \
      --dump-header "$WORK/headers" --output "$output" --write-out '%{http_code}' ||
      fail network_error "HTTP request failed or exceeded its time/size limit. Check connectivity, TLS certificates and credentials. A failed write may have reached Zotero; rerun sync to reconcile."
    HTTP_CODE="$(<"$WORK/http-code")"
    [[ $(wc -c < "$output") -le $bytes ]] ||
      fail download_error "Response exceeds the configured size limit."
}
check_webdav_connection() {
    [[ $USE_WEBDAV == true ]] ||
        fail configuration_error "WebDAV connection testing requires use_webdav = true."
    request webdav "$(get_config webdav_url)" "$WORK/webdav-check.xml" 65536 "$WEBDAV_TIMEOUT" PROPFIND
    [[ $HTTP_CODE == 207 ]] ||
        fail webdav_error "WebDAV directory request returned HTTP $HTTP_CODE. Check the URL, credentials and access permissions."
}
metadata() {
    request zotero "$API/$1" "$2" 8388608 "$ZOTERO_TIMEOUT"
    [[ $HTTP_CODE == 200 ]] || fail zotero_error "Zotero metadata request returned HTTP $HTTP_CODE. Check request parameters, access permissions and API rate limits."
    "$JQ" -e '.' "$2" >/dev/null || fail zotero_error "Zotero returned invalid metadata JSON."
}
find_attachment() {
    local key=$1 start=0 count
    ATTACHMENT=
    while :; do
        metadata "items/$key/children?limit=100&start=$start" "$WORK/children.json"
        "$JQ" -e 'type=="array"' "$WORK/children.json" >/dev/null || fail zotero_error "Invalid attachment metadata."
        ATTACHMENT="$("$JQ" -r '[.[]|.data|select(.contentType=="application/pdf" and
          (.linkMode=="imported_file" or .linkMode=="imported_url"))][0].key // ""' "$WORK/children.json")"
        if [[ -n $ATTACHMENT ]]; then
            [[ $ATTACHMENT =~ ^[A-Z0-9]{8}$ ]] || fail zotero_error "Zotero returned an invalid attachment key."
            return
        fi
        count="$("$JQ" 'length' "$WORK/children.json")"
        ((count == 100)) || return 0
        start=$((start + count))
        ((start < 10000)) || fail zotero_error "Attachment pagination exceeded the safety limit."
    done
}

list_pdf_attachments() {
    local start=0 count
    : >"$WORK/child-pdfs.jsonl"
    while :; do
        metadata "items/$ITEM_KEY/children?limit=100&start=$start" "$WORK/children.json"
        "$JQ" -e 'type=="array"' "$WORK/children.json" >/dev/null || fail zotero_error "Invalid attachment metadata."
        "$JQ" -c '.[]|select(.data.contentType=="application/pdf" and
          (.data.linkMode=="imported_file" or .data.linkMode=="imported_url"))
          |{attachment_key:.data.key,title:((.data.title // .data.filename // "")|tostring)}' \
          "$WORK/children.json" >>"$WORK/child-pdfs.jsonl"
        count="$("$JQ" 'length' "$WORK/children.json")"
        ((count == 100)) || break
        start=$((start + count))
        ((start < 10000)) || fail zotero_error "Attachment pagination exceeded the safety limit."
    done
    "$JQ" -se --arg key "$ITEM_KEY" '
      if map(.attachment_key) | all(test("^[A-Z0-9]{8}$")) then
        {ok:true,item_key:$key,attachments:.}
      else error("invalid attachment key") end' \
      "$WORK/child-pdfs.jsonl" >"$WORK/children-result.json" ||
      fail zotero_error "Zotero returned an invalid attachment key."
    if [[ $AS_JSON == true ]]; then "$JQ" '.' "$WORK/children-result.json"
    else "$JQ" -r '.attachments[]|[.attachment_key,.title]|@tsv' "$WORK/children-result.json"; fi
}

total_results() {
    TOTAL_RESULTS="$("$JQ" -Rse '[split("\n")[] | select(ascii_downcase | startswith("total-results:"))
      | capture("^Total-Results:[ \t]*(?<value>[0-9]+)[ \t\r]*$";"i")
      | .value | tonumber] | last // error("missing total")' "$WORK/headers")" ||
      fail zotero_error "Zotero response is missing a valid Total-Results header."
}

list_zotero_library() {
    local encoded_query paper key has_pdf tag_parameter= encoded_tags total count next_skip base_path
    load_state
    encoded_query="$(printf '%s' "$QUERY" | "$JQ" -Rrs '@uri')"
    if ((${#TAGS[@]})); then
        encoded_tags="$("$JQ" -nr --args '
          $ARGS.positional | map(
            if length==0 or contains("||") or startswith("\\-") or test("[\u0000-\u001f\u007f]")
            then error("invalid literal tag") else . end)
          | join(" || ") | if startswith("-") then "\\"+. else . end
          | @uri' -- "${TAGS[@]}")" ||
          fail ValueError "Tags must be nonempty literal names without controls, '||', or a leading backslash-hyphen."
        tag_parameter="&tag=$encoded_tags"
    fi
    base_path="items/top"
    [[ -z $COLLECTION ]] || base_path="collections/$COLLECTION/items/top"
    # Zotero permits one itemType parameter; leading '-' negates the OR group.
    metadata "$base_path?limit=$LIMIT&start=$SKIP&q=$encoded_query&itemType=-attachment%20%7C%7C%20note%20%7C%7C%20annotation&sort=dateModified&direction=desc$tag_parameter" "$WORK/items.json"
    "$JQ" -e 'type=="array"' "$WORK/items.json" >/dev/null || fail zotero_error "Invalid item list."
    total_results
    total=$TOTAL_RESULTS
    count="$("$JQ" 'length' "$WORK/items.json")"
    ((count <= LIMIT)) || fail zotero_error "Zotero returned an oversized page."
    next_skip=null
    if ((SKIP + count < total)); then
        ((count > 0)) || fail zotero_error "Zotero returned an empty page before the end; refresh the listing."
        next_skip=$((SKIP + count))
    fi
    "$JQ" -c '.[]|select(.data.itemType!="attachment" and .data.itemType!="note" and .data.itemType!="annotation")
      |{key:.data.key,title:.data.title,date:.data.date,numChildren:(.meta.numChildren // 0)}' \
      "$WORK/items.json" >"$WORK/items.jsonl"
    : >"$WORK/papers.jsonl"
    while IFS= read -r paper; do
        printf '%s\n' "$paper" >"$WORK/paper.json"
        key="$("$JQ" -r '.key' "$WORK/paper.json")"
        [[ $key =~ ^[A-Z0-9]{8}$ ]] || fail zotero_error "Zotero returned an invalid item key."
        find_mapping "$key"
        num_children="$("$JQ" '.numChildren' "$WORK/paper.json")"
        has_pdf="$("$JQ" '.numChildren > 0' "$WORK/paper.json")"
        "$JQ" -c --argjson pdf "$has_pdf" --argjson children "$num_children" --arg scope "$LIBRARY_SCOPE" --arg key "$key" \
          --slurpfile mapping "$WORK/mapping.json" --slurpfile state "$WORK/state.json" '
          {item_key:.key,title:((.title // "")|gsub("^\\s+|\\s+$";"")),
           year:((.date // "")|tostring|gsub("^\\s+|\\s+$";"")),has_pdf:$pdf,num_children:$children,
           mapping:$mapping[0],attempt:($state[0].attempts[$scope][$key] // null)}' "$WORK/paper.json" >>"$WORK/papers.jsonl"
    done <"$WORK/items.jsonl"
    if [[ $PAGE_INFO == true ]]; then
        "$JQ" -s --argjson skip "$SKIP" --argjson limit "$LIMIT" --argjson total "$total" \
          --argjson next "$next_skip" '{ok:true,items:.,pagination:{
            skip:$skip,limit:$limit,total:$total,has_more:($next!=null),next_skip:$next}}' "$WORK/papers.jsonl"
    elif [[ $AS_JSON == true ]]; then "$JQ" -s '.' "$WORK/papers.jsonl"
    else "$JQ" -r '[.item_key,("files~" + (.num_children|tostring)),.year,.title]|@tsv' "$WORK/papers.jsonl"; fi
}

list_zotero_tags() {
    local start=0 count total encoded_query
    lock_state
    load_state
    if [[ $REFRESH == false ]] && "$JQ" -e --arg scope "$LIBRARY_SCOPE" --arg query "$QUERY" \
      '.tag_cache[$scope] | has($query)' "$WORK/state.json" >/dev/null; then
        "$JQ" --arg scope "$LIBRARY_SCOPE" --arg query "$QUERY" \
          '.tag_cache[$scope][$query].tags' "$WORK/state.json" >"$WORK/tag-names.json"
        exec {json_lock}>&-
        print_zotero_tags
        return
    fi
    encoded_query="$(printf '%s' "$QUERY" | "$JQ" -Rrs '@uri')"
    : >"$WORK/tags.jsonl"
    while :; do
        metadata "tags?limit=100&start=$start&q=$encoded_query" "$WORK/tags.json"
        "$JQ" -e 'type=="array" and all(.[]; .tag|type=="string")' "$WORK/tags.json" >/dev/null ||
            fail zotero_error "Zotero returned invalid tag data."
        total_results
        total=$TOTAL_RESULTS
        count="$("$JQ" 'length' "$WORK/tags.json")"
        ((count <= 100)) || fail zotero_error "Zotero returned an oversized tag page."
        "$JQ" -c '.[]|.tag' "$WORK/tags.json" >>"$WORK/tags.jsonl"
        start=$((start + count))
        ((start < total)) || break
        ((count > 0)) || fail zotero_error "Zotero returned an empty tag page before the end; retry."
    done
    "$JQ" -s 'unique' "$WORK/tags.jsonl" >"$WORK/tag-names.json"
    "$JQ" --arg scope "$LIBRARY_SCOPE" --arg query "$QUERY" \
      --slurpfile names "$WORK/tag-names.json" \
      '.tag_cache[$scope][$query]={fetched_at:(now|floor),tags:$names[0]}' \
      "$WORK/state.json" >"$WORK/state-next.json"
    save_state
    exec {json_lock}>&-
    print_zotero_tags
}
print_zotero_tags() {
    if [[ $AS_JSON == true ]]; then "$JQ" '.' "$WORK/tag-names.json"
    else "$JQ" -r '.[]' "$WORK/tag-names.json"; fi
}
list_zotero_collections() {
    local start=0 count total
    lock_state
    load_state
    if [[ $REFRESH == false ]] && "$JQ" -e --arg scope "$LIBRARY_SCOPE" \
      '.collection_cache | has($scope)' "$WORK/state.json" >/dev/null; then
        "$JQ" --arg scope "$LIBRARY_SCOPE" \
          '.collection_cache[$scope].collections' "$WORK/state.json" >"$WORK/collection-names.json"
        exec {json_lock}>&-
        print_zotero_collections
        return
    fi
    : >"$WORK/collections.jsonl"
    while :; do
        metadata "collections/top?limit=100&start=$start" "$WORK/collections.json"
        "$JQ" -e 'type=="array" and all(.[]; .data.key|type=="string")' "$WORK/collections.json" >/dev/null ||
            fail zotero_error "Zotero returned invalid collection data."
        total_results
        total=$TOTAL_RESULTS
        count="$("$JQ" 'length' "$WORK/collections.json")"
        ((count <= 100)) || fail zotero_error "Zotero returned an oversized collection page."
        "$JQ" -c '.[]|.data|select(.key|test("^[A-Z0-9]{8}$"))
          |{key:.key,name:((.name // "")|tostring|gsub("^\\s+|\\s+$";""))}' \
          "$WORK/collections.json" >>"$WORK/collections.jsonl"
        start=$((start + count))
        ((start < total)) || break
        ((count > 0)) || fail zotero_error "Zotero returned an empty collection page before the end; retry."
    done
    "$JQ" -s 'sort_by(.name)' "$WORK/collections.jsonl" >"$WORK/collection-names.json"
    "$JQ" --arg scope "$LIBRARY_SCOPE" --slurpfile collections "$WORK/collection-names.json" \
      '.collection_cache[$scope]={fetched_at:(now|floor),collections:$collections[0]}' \
      "$WORK/state.json" >"$WORK/state-next.json"
    save_state
    exec {json_lock}>&-
    print_zotero_collections
}
print_zotero_collections() {
    if [[ $AS_JSON == true ]]; then "$JQ" '.' "$WORK/collection-names.json"
    else "$JQ" -r '.[]|[.key,.name]|@tsv' "$WORK/collection-names.json"; fi
}
pdf_valid() {
    [[ -f $1 ]] || return 1
    # jq retains NUL bytes, unlike Bash command substitution.
    dd bs=1024 count=1 <"$1" | "$JQ" -Rse \
      'sub("^[ \t\r\n\u000b\f]*";"") | startswith("%PDF-")' >/dev/null
}
extract_pdf() {
    local help member expected format
    local -a options
    if [[ -n $SEVEN_ZIP ]]; then
        format=7zz
        options=(e -so -bd -y -spd)
        limited_command 8388608 "$WORK/zip-list" "$SEVEN_ZIP" l -slt -ba "$WORK/download.zip" < /dev/null ||
            fail archive_error "Cannot list the item's WebDAV ZIP, or its listing exceeds the size limit."
    else
        format=unzip
        help="$(unzip -h 2>&1 || :)"
        case "$help" in
            *BusyBox*) options=(-p) ;;
            *UnZip*|*Info-ZIP*) options=(-p -P '') ;;
            *) fail missing_dependency "PDF extraction requires bundled 7zz, BusyBox or Info-ZIP unzip." ;;
        esac
        limited_command 8388608 "$WORK/zip-list" unzip -l "$WORK/download.zip" < /dev/null ||
            fail archive_error "Cannot list the item's WebDAV ZIP, or its listing exceeds the size limit."
    fi
    "$JQ" -Rse --arg format "$format" --slurpfile attachment "$WORK/attachment.json" --argjson limit "$MAX_BYTES" \
      -f "$ROOT_DIR/scripts/zotbridge-shell-zip.jq" "$WORK/zip-list" >"$WORK/zip-selected.json" ||
        fail archive_error "The item's WebDAV ZIP has an unsupported listing/name, duplicate entries, or no unique PDF within the size limit."
    member="$("$JQ" -r '.raw' "$WORK/zip-selected.json")"
    expected="$("$JQ" -r '.size' "$WORK/zip-selected.json")"
    # Never extract archive paths into the filesystem or allow password prompts.
    if [[ $format == 7zz ]]; then
        limited_command "$expected" "$WORK/document.pdf" "$SEVEN_ZIP" "${options[@]}" \
          "$WORK/download.zip" "$member" < /dev/null
    else
        limited_command "$expected" "$WORK/document.pdf" unzip "${options[@]}" \
          "$WORK/download.zip" "$member" < /dev/null
    fi ||
        fail archive_error "The item's PDF extraction failed or exceeded its size bound; check for a corrupt or encrypted ZIP."
    [[ $(wc -c < "$WORK/document.pdf") -eq $expected ]] ||
        fail archive_error "The item's extracted PDF size does not match the ZIP listing."
    rm -f -- "$WORK/download.zip"
}
download_pdf() {
    [[ -n ${ATTACHMENT:-} ]] || resolve_attachment
    [[ -n $ATTACHMENT ]] || fail RuntimeError "No stored PDF attachment found for the item."
    if [[ $USE_WEBDAV == true ]]; then
        [[ -s $WORK/attachment.json ]] || metadata "items/$ATTACHMENT" "$WORK/attachment.json"
        local dav_url
        dav_url="$(get_config webdav_url)"
        request webdav "$dav_url$ATTACHMENT.zip" "$WORK/download.zip" "$MAX_BYTES" "$WEBDAV_TIMEOUT"
        [[ $HTTP_CODE == 200 ]] || fail webdav_error "WebDAV download was not HTTP 200. Check credentials and the exact Zotero ZIP directory; redirects are refused."
        extract_pdf
    else
        request zotero "$API/items/$ATTACHMENT/file" "$WORK/document.pdf" "$MAX_BYTES" "$ZOTERO_TIMEOUT"
        if [[ $HTTP_CODE =~ ^30[12378]$ ]]; then
            # Deliberately strip ALL credentials on the storage redirect. Only one
            # absolute HTTPS hop is supported, never curl -L with an API header.
            "$JQ" -Rse '[split("\n")[]|sub("\r$";"")|select(test("^location:";"i"))
              | sub("^[^:]+:\\s*";"")]|if length==1 and
              (.[0]|test("^https://[^/@?#\\s]+(?:/[^\\s]*)?$")) then .[0] else error("redirect") end' \
              "$WORK/headers" >"$WORK/location.json" ||
                fail zotero_error "Unsupported Zotero Storage redirect; expected one absolute HTTPS location."
            request none "$("$JQ" -r '.' "$WORK/location.json")" "$WORK/document.pdf" "$MAX_BYTES" "$ZOTERO_TIMEOUT"
        fi
        [[ $HTTP_CODE == 200 ]] || fail zotero_error "Zotero Storage download was not HTTP 200; only one credential-free HTTPS redirect is supported."
    fi
    pdf_valid "$WORK/document.pdf" || fail download_error "Downloaded attachment is not a PDF."
    metadata "items/$ITEM_KEY" "$WORK/item.json"
    local title
    title="$("$JQ" -r --arg key "$ITEM_KEY" '
      (.data.title // $key)|tostring|gsub("^\\s+|\\s+$";"")
      | gsub("</?(?:i|b|sub|sup|span)(?:\\s+[^>]*)?>";"";"i")
      | gsub("[<>:\"/\\\\|?*\u0000-\u001f\u007f,]";"")
      | gsub("\\s+";" ")|gsub("^[ .]+|[ .]+$";"")
      | explode | reduce .[] as $c ({s:"",n:0,full:false};
          ($c|[.]|implode) as $char | ($char|utf8bytelength) as $n
          | if .full or .n+$n>180 then .full=true else .s+=$char|.n+=$n end) | .s
      | sub("[ .]+$";"") | if length==0 then $key else . end
      | if test("^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|$)";"i") then "_"+. else . end' "$WORK/item.json")"
    PDF_PATH="$WORK/$title.pdf"
    [[ $PDF_PATH == "$WORK/document.pdf" ]] || mv -- "$WORK/document.pdf" "$PDF_PATH"
}

uuid_valid() { [[ $1 =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; }
validate_target_folder() {
    local compact_target
    [[ $TARGET != *$'\n'* && $TARGET != *$'\r'* ]] || fail ValueError "target-folder must not contain newlines."
    printf '%s' "$TARGET" | "$JQ" -Rse 'split("/")|all(gsub("^\\s+|\\s+$";"")|length>0)' >/dev/null ||
        fail ValueError "target-folder must be nonempty with no empty path components."
    compact_target="${TARGET#urn:uuid:}"
    compact_target="${compact_target#\{}"; compact_target="${compact_target%\}}"
    compact_target="${compact_target//-/}"
    [[ ! $compact_target =~ ^[[:xdigit:]]{32}$ ]] ||
        fail ValueError "target-folder must be a folder path, not an unchecked UUID."
}
broker() {
    local signal=$1 params=$2 reply_type=${3:-uuid} payload identity previous reply result deadline
    [[ $params != *$'\n'* && $params != *$'\r'* ]] || fail ValueError "Broker parameters must not contain newlines."
    payload=">e$signal:$params"$'\n'
    ((${#payload} <= 1024)) || fail ValueError "Message broker request exceeds its 1024-byte UTF-8 limit."
    [[ -p $MB_IN && -p $MB_OUT ]] || fail ValueError "Both message broker paths must be FIFOs."
    exec {broker_lock}>>"$MB_IN.zotbridge.lock"
    flock -n "$broker_lock" || fail busy "Another bridge broker operation is running; try later."
    identity="$(stat -Lc '[%d,%i]' -- "$MB_IN" "$MB_OUT" | "$JQ" -sc '.')"
    if [[ -e $MB_IN.zotbridge-pending ]]; then
        previous="$("$JQ" -ce '.' "$MB_IN.zotbridge-pending")" ||
            fail BrokerRecoveryRequired "Unreadable recovery marker. Recreate the broker FIFOs and inspect the marker before retrying."
        [[ $previous != "$identity" ]] ||
            fail BrokerRecoveryRequired "An earlier broker request was not confirmed. Restart xochitl with XOVI to recreate its FIFOs before retrying; imports may already exist."
        rm -f -- "$MB_IN.zotbridge-pending"
    fi
    # Publish before starting the worker so timeout, signal, and process death all
    # conservatively block stale-response reuse. Compatible with Python's marker.
    printf '%s\n' "$identity" >"$WORK/pending"
    cp_pending="$MB_IN.zotbridge-pending.new.$$"
    (set -o noclobber; printf '%s\n' "$identity" >"$cp_pending")
    mv -f -- "$cp_pending" "$MB_IN.zotbridge-pending"
    deadline="$("$JQ" -n --argjson t "$BROKER_TIMEOUT" '($t*100)|ceil')"
    # Only Bash builtins in this worker: one exact PID can cancel blocked FIFO
    # opens, writes, or EOF reads without leaving a cat/timeout/watchdog child.
    (
        trap - EXIT ERR HUP INT TERM
        exec {writer}>"$MB_IN"
        printf '%s' "$payload" >&"$writer"
        exec {writer}>&-
        exec {reader}<"$MB_OUT"
        response=
        # NUL or a full 65537-byte read is invalid; only EOF ends a reply.
        # -d "" also prevents Bash silently discarding embedded NUL bytes.
        if IFS= read -r -d '' -n 65537 response <&"$reader"; then exit 2; fi
        printf '%s' "$response" >"$WORK/broker-reply"
        exec {reader}<&-
    ) 2>/dev/null &
    WORKER=$!
    local tick=0
    while kill -0 "$WORKER" 2>/dev/null; do
        if ((tick >= deadline)); then
            kill -KILL "$WORKER" 2>/dev/null || :
            wait "$WORKER" 2>/dev/null || :
            WORKER=
            fail TimeoutError "Timed out waiting for xovi-message-broker. Recreate its FIFOs before another broker operation; check for an existing import."
        fi
        sleep 0.01
        tick=$((tick + 1))
    done
    result=0
    wait "$WORKER" || result=$?
    WORKER=
    ((result == 0)) || fail broker_error "Broker worker failed or response exceeded 65536 bytes. Recreate its FIFOs before retrying."
    rm -f -- "$MB_IN.zotbridge-pending"
    exec {broker_lock}>&-
    reply="$("$JQ" -Rrs 'gsub("^\\s+|\\s+$";"")' "$WORK/broker-reply")"
    [[ $reply != ERROR:* ]] || fail broker_error "rm-librarian reported an error; no import success was recorded."
    if [[ $reply_type == uuid ]]; then
        [[ -n $reply ]] || fail broker_error "rm-librarian returned an empty response."
        uuid_valid "$reply" || fail broker_error "rm-librarian returned a noncanonical UUID."
        BROKER_UUID="${reply,,}"
    fi
    BROKER_REPLY=$reply
}

doc_status() {
    local uuid=$1 title= item_key attachment_key updated_at
    load_state
    "$JQ" -c --arg uuid "$uuid" '.mappings[$uuid] // null' "$WORK/state.json" >"$WORK/doc-status-mapping.json"
    if "$JQ" -e '.==null' "$WORK/doc-status-mapping.json" >/dev/null; then
        "$JQ" -cn --arg uuid "$uuid" '{ok:true,rm_uuid:$uuid,mapped:false}'
        return
    fi
    item_key="$("$JQ" -r '.zotero_item_key' "$WORK/doc-status-mapping.json")"
    attachment_key="$("$JQ" -r '.zotero_attachment_key' "$WORK/doc-status-mapping.json")"
    updated_at="$("$JQ" -r '.updated_at' "$WORK/doc-status-mapping.json")"
    if [[ $item_key =~ ^[A-Z0-9]{8}$ ]]; then
        request zotero "$API/items/$item_key" "$WORK/doc-status-item.json" 8388608 "$ZOTERO_TIMEOUT"
        if [[ $HTTP_CODE == 200 ]] && "$JQ" -e '.' "$WORK/doc-status-item.json" >/dev/null 2>&1; then
            title="$("$JQ" -r '.data.title // ""' "$WORK/doc-status-item.json")"
        fi
    fi
    "$JQ" -cn --arg uuid "$uuid" --arg item "$item_key" --arg attachment "$attachment_key" \
      --arg title "$title" --arg updated "$updated_at" \
      '{ok:true,rm_uuid:$uuid,mapped:true,zotero_item_key:$item,zotero_attachment_key:$attachment,
        zotero_item_title:$title,updated_at:$updated}'
}
doc_tags() {
    local uuid=$1
    local metadata_path="$LIBRARY/$uuid.metadata"
    [[ -f $metadata_path && ! -L $metadata_path ]] ||
        fail FileNotFoundError "No reMarkable document found with that UUID."
    "$JQ" -e 'type=="object" and .type=="DocumentType" and (.deleted // false)==false' \
      "$metadata_path" >/dev/null ||
        fail FileNotFoundError "That reMarkable UUID is not an active document."
    "$JQ" -c --arg uuid "$uuid" '{ok:true,rm_uuid:$uuid,
      rm_title:(.visibleName // ""),
      tags:((.tags // [])
        | map(if type=="object" then (.name // empty) elif type=="string" then . else empty end)
        | map(select(length>0)) | unique)}' "$metadata_path" ||
        fail state_error "reMarkable document metadata could not be read."
}

library_list() {
    [[ -d $LIBRARY ]] || fail FileNotFoundError "reMarkable library directory not found."
    : >"$WORK/library.jsonl"
    local path id
    shopt -s nullglob
    for path in "$LIBRARY"/*.metadata; do
        id="${path##*/}"; id="${id%.metadata}"
        if uuid_valid "$id" && "$JQ" -e '
          type=="object" and ([.visibleName,.parent,.type]|all(type=="string"))
          and (.type=="DocumentType" or .type=="CollectionType")' "$path" >/dev/null; then
            "$JQ" -c --arg id "${id,,}" '{entry:{rm_uuid:$id,title:.visibleName,
              parent:.parent,type:.type,deleted:(.deleted // false)}}' "$path" >>"$WORK/library.jsonl"
        else
            "$JQ" -cn --arg file "${path##*/}" '{warning:($file+": invalid or unreadable metadata")}' >>"$WORK/library.jsonl"
        fi
    done
    "$JQ" -s -f "$ROOT_DIR/scripts/zotbridge-shell-library.jq" "$WORK/library.jsonl"
}

source "$ROOT_DIR/scripts/zotbridge-shell-sync.sh"
source "$ROOT_DIR/scripts/zotbridge-shell-reverse.sh"

case "$COMMAND" in
    settings) ACTIVITY_LOGGED=true; show_settings ;;
    settings-apply) apply_settings ;;
    activity-log) ACTIVITY_LOGGED=true; print_activity_log ;;
    clear-activity-log) clear_activity_log ;;
    sync-tagged) sync_tagged || { ACTIVITY_LOGGED=true; exit 1; } ;;
    reverse-sync)
        # Captured via command substitution (a subshell) rather than redirected to a
        # WORK file: fail() calls exit, which would otherwise only terminate the whole
        # process before this case block could print the WORK file back out, leaving
        # any internal failure (e.g. broker unavailable) completely silent on stdout.
        reverse_result="$(reverse_sync)" || true
        [[ -n $reverse_result ]] ||
          reverse_result='{"ok":false,"error":"runtime_error","message":"reverse-sync produced no output; check the activity log."}'
        printf '%s\n' "$reverse_result" | "$JQ" '.'
        printf '%s\n' "$reverse_result" | "$JQ" -e '.ok' >/dev/null ||
          { ACTIVITY_LOGGED=true; exit 1; }
        ACTIVITY_LOGGED=true
        ;;
    sync-all)
        sync_all || { ACTIVITY_LOGGED=true; exit 1; }
        ACTIVITY_LOGGED=true
        ;;
    sync-item) sync_item ;;
    doc-status) ACTIVITY_LOGGED=true; doc_status "$UUID_OPT" ;;
    doc-tags) ACTIVITY_LOGGED=true; doc_tags "$UUID_OPT" ;;
    queue-for-zotero)
        ACTIVITY_LOGGED=true
        queue_for_zotero "$UUID_OPT" "$QUEUE_MODE" "$QUEUE_PARENT_KEY" "$COLLECTION" "$QUEUE_TAGS_RAW" "$QUEUE_ANNOTATED_ONLY"
        ;;
    clear-mappings) clear_state_mappings ;;
    ensure-folder)
        validate_target_folder
        broker ensureFolder "$TARGET"
        "$JQ" -cn --arg path "$TARGET" --arg uuid "$BROKER_UUID" \
          '{ok:true,folder_path:$path,folder_uuid:$uuid}'
        ;;
    tags) list_zotero_tags ;;
    collections) list_zotero_collections ;;
    library) library_list ;;
    children) list_pdf_attachments ;;
    status)
        load_state
        find_mapping
        "$JQ" --arg key "$ITEM_KEY" --arg scope "$LIBRARY_SCOPE" --slurpfile mapping "$WORK/mapping.json" '
          if $mapping[0]!=null then {ok:true,mapping:$mapping[0]}
          elif .attempts[$scope][$key]!=null then {ok:false,error:"import_uncertain",attempt:.attempts[$scope][$key]}
          else {ok:false,error:"not_found",item_key:$key} end' "$WORK/state.json" >"$WORK/result.json"
        "$JQ" '.' "$WORK/result.json"
        "$JQ" -e '.ok' "$WORK/result.json" >/dev/null || exit 1
        ;;
    check-connection)
        storage=zotero; [[ $USE_WEBDAV != true ]] || storage=webdav
        if [[ -n $ITEM_KEY ]]; then
            download_pdf
            "$JQ" -cn --arg storage "$storage" --argjson bytes "$(wc -c < "$PDF_PATH")" \
              '{ok:true,metadata:"accessible",storage:$storage,pdf_download:"verified",bytes:$bytes}'
        elif [[ ${CHECK_WEBDAV:-false} == true ]]; then
            metadata 'items/top?limit=1' "$WORK/items.json"
            check_webdav_connection
            "$JQ" -cn '{ok:true,metadata:"accessible",webdav:"accessible",
              pdf_download:"not_tested",message:"Read-only Zotero metadata and WebDAV directory checks passed."}'
        else
            metadata 'items/top?limit=1' "$WORK/items.json"
            "$JQ" -cn --arg storage "$storage" '{ok:true,metadata:"accessible",storage:$storage,
              pdf_download:"not_tested",message:"Use --item-key with a parent item containing a PDF to test file access."}'
        fi
        ;;
    list)
        list_zotero_library
        ;;
    import)
        begin_import
        find_mapping
        if "$JQ" -e '.!=null' "$WORK/mapping.json" >/dev/null; then
            "$JQ" '{ok:true,already_imported:true,mapping:.}' "$WORK/mapping.json"
            exit 0
        fi
        if [[ $RETRY != true ]] && "$JQ" -e --arg key "$ITEM_KEY" --arg scope "$LIBRARY_SCOPE" \
          '.attempts[$scope][$key]!=null' "$WORK/state.json" >/dev/null; then
            fail import_uncertain "A previous import was not confirmed. Check the tablet library before --retry-uncertain; retrying may create a duplicate."
        fi
        if [[ -n $ATTACHMENT_KEY_OPT ]]; then
            metadata "items/$ITEM_KEY" "$WORK/item.json"
            "$JQ" -e --arg key "$ITEM_KEY" '.data.key==$key and (.data.itemType|type=="string")' \
              "$WORK/item.json" >/dev/null || fail zotero_error "Invalid source item metadata."
            metadata "items/$ATTACHMENT_KEY_OPT" "$WORK/attachment-check.json"
            "$JQ" -e --arg key "$ATTACHMENT_KEY_OPT" --arg parent "$ITEM_KEY" '
              .data.key==$key and .data.parentItem==$parent and .data.contentType=="application/pdf"
              and (.data.linkMode=="imported_file" or .data.linkMode=="imported_url")' \
              "$WORK/attachment-check.json" >/dev/null ||
              fail unsupported_item "The requested attachment is not a stored PDF that belongs to this item."
            ATTACHMENT=$ATTACHMENT_KEY_OPT
        else
            resolve_attachment
        fi
        import_selected_pdf
        REMARKABLE_TAGS_UPDATED=false
        REMARKABLE_TAGS_ERROR=
        if [[ ($INCLUDE_ZOTERO_TAGS == true || $ADD_UNREAD_TAG == true) ]] &&
          "$JQ" -e '.already_imported==false' "$WORK/import-result.json" >/dev/null; then
            DOCUMENT_UUID="$("$JQ" -r '.rm_uuid' "$WORK/import-result.json")"
            if (apply_selected_tags) >"$WORK/tag-result.json"; then
                REMARKABLE_TAGS_UPDATED=true
            else
                REMARKABLE_TAGS_ERROR="$("$JQ" -r '.error // "tag_update_error"' "$WORK/tag-result.json" 2>/dev/null ||
                  printf '%s' tag_update_error)"
            fi
        fi
        "$JQ" --argjson tags_updated "$REMARKABLE_TAGS_UPDATED" --arg tags_error "$REMARKABLE_TAGS_ERROR" \
          '.+{remarkable_tags_updated:$tags_updated}
          + (if $tags_error=="" then {} else {remarkable_tags_error:$tags_error} end)' \
          "$WORK/import-result.json"
        ;;
esac
