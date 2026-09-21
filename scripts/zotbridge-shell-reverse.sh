#!/usr/bin/env bash
# Reverse synchronization helpers; sourced by zotbridge-shell.sh after runtime setup.

reverse_activity() {
    local event=$1 uuid=${2:-} stage=${3:-} error=${4:-} retained=${5:-} count=${6:-} line
    (
        exec {reverse_log_lock}>>"$ACTIVITY_LOG.lock"
        flock -n "$reverse_log_lock" || exit 0
        line="$("$JQ" -cn --arg event "$event" --arg uuid "$uuid" --arg stage "$stage" \
          --arg error "$error" --arg retained "$retained" --arg count "$count" '
          {timestamp:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),action:"reverse-sync",event:$event}
          + (if $uuid=="" then {} else {rm_uuid:$uuid} end)
          + (if $stage=="" then {} else {stage:$stage} end)
          + (if $error=="" then {} else {error:$error} end)
          + (if $retained=="" then {} else {retained_in_source:($retained=="true")} end)
          + (if $count=="" then {} else {count:($count|tonumber)} end)')"
        if [[ -e $ACTIVITY_LOG ]] && (( $(wc -l <"$ACTIVITY_LOG") >= 200 )); then
            local stage_file="$ACTIVITY_LOG.new.$$.$RANDOM"
            tail -n 199 "$ACTIVITY_LOG" >"$stage_file"
            printf '%s\n' "$line" >>"$stage_file"
            mv -f -- "$stage_file" "$ACTIVITY_LOG"
        else
            printf '%s\n' "$line" >>"$ACTIVITY_LOG"
        fi
    ) || :
}

reverse_fail() {
    local uuid=$1 stage=$2 error=$3
    reverse_activity failed "$uuid" "$stage" "$error" true
    "$JQ" -cn --arg uuid "$uuid" --arg stage "$stage" --arg error "$error" \
      '{ok:false,rm_uuid:$uuid,stage:$stage,error:$error,retained_in_source:true}'
    return 1
}

reverse_http() {
    local auth=$1 method=$2 url=$3 output=$4 body=${5:-} content_type=${6:-} write_token=
    if [[ $auth == zotero && $method == POST && -n $body ]]; then
        write_token="$(sha256sum "$body" | cut -c1-32)"
    fi
    printf '%s' "$url" >"$WORK/reverse-url"
    "$JQ" -nr --rawfile url "$WORK/reverse-url" --arg auth "$auth" --arg method "$method" \
      --arg body "$body" --arg content "$content_type" --arg token "$write_token" \
      --slurpfile cfg "$WORK/config.json" '
      "url = \($url|@json)", "silent", "request = \($method|@json)",
      "proto = \"=http,https\"", "max-redirs = 0", "connect-timeout = 60", "max-time = 300",
      (if $auth=="zotero" then
         "header = \(("Zotero-API-Key: "+$cfg[0].api_key)|@json)",
         "header = \"Zotero-API-Version: 3\""
       else
         "user = \(($cfg[0].webdav_username+":"+$cfg[0].webdav_password)|@json)", "basic"
       end),
      (if $token!="" then "header = \(("Zotero-Write-Token: "+$token)|@json)" else empty end),
      (if $content!="" then "header = \(("Content-Type: "+$content)|@json)" else empty end),
      (if $body!="" then "data-binary = \(("@"+$body)|@json)" else empty end)' >"$WORK/reverse-curl.conf"
    chmod 600 "$WORK/reverse-curl.conf"
    "$CURL" -q --config "$WORK/reverse-curl.conf" --dump-header "$WORK/reverse-headers" \
      --output "$output" --write-out '%{http_code}' >"$WORK/reverse-code" 2>/dev/null || return 1
    REVERSE_HTTP_CODE="$(<"$WORK/reverse-code")"
}

reverse_key() {
    printf '%s' "$1:$2" | sha256sum | cut -c1-8 | tr '01abcdef' 'ABABCDEF'
}

resolve_reverse_folder() {
    REVERSE_FOLDER="$(get_config reverse_sync_folder)"
    TARGET="$REVERSE_FOLDER"
    validate_target_folder
    broker ensureFolder "$REVERSE_FOLDER"
    REVERSE_FOLDER_UUID=$BROKER_UUID
}

snapshot_reverse_documents() {
    resolve_reverse_folder
    : >"$WORK/reverse-documents.jsonl"
    local metadata_path uuid
    shopt -s nullglob
    for metadata_path in "$LIBRARY"/*.metadata; do
        uuid="${metadata_path##*/}"; uuid="${uuid%.metadata}"
        uuid_valid "$uuid" || continue
        "$JQ" -e --arg parent "$REVERSE_FOLDER_UUID" '
          .type=="DocumentType" and .deleted!=true and .parent==$parent
          and (.visibleName|type=="string" and length>0)' "$metadata_path" >/dev/null || continue
        "$JQ" -c --arg uuid "${uuid,,}" '{rm_uuid:$uuid,name:.visibleName}' \
          "$metadata_path" >>"$WORK/reverse-documents.jsonl"
    done
}

export_pdf_from_path() {
    local uuid=$1 name=$2 source_path=$3
    [[ -n $RMAPI ]] || return 1
    rmapi_paired || return 1
    RMAPI_CONFIG="$RMAPI_CONFIG" "$RMAPI" -json ls "$(dirname -- "$source_path")" >"$WORK/cloud-list.json" 2>/dev/null ||
      return 1
    "$JQ" -e --arg uuid "$uuid" --arg name "$name" '
      [.[]|select(.id==$uuid and .name==$name and .type=="DocumentType")]|length==1' \
      "$WORK/cloud-list.json" >/dev/null || return 1
    rm -rf "$WORK/export"
    mkdir -p "$WORK/export"
    (
      cd "$WORK/export"
      RMAPI_CONFIG="$RMAPI_CONFIG" "$RMAPI" geta --a "$source_path" >/dev/null 2>&1
    ) || return 1
    mapfile -t reverse_pdfs < <(find "$WORK/export" -maxdepth 1 -type f -name '*.pdf')
    ((${#reverse_pdfs[@]} == 1)) || return 1
    REVERSE_PDF=${reverse_pdfs[0]}
    pdf_valid "$REVERSE_PDF" || return 1
}

export_reverse_pdf() {
    local uuid=$1 name=$2
    export_pdf_from_path "$uuid" "$name" "$REVERSE_FOLDER/$name"
}

# Reconstructs the current on-device cloud path of a single document from
# local metadata, independent of which folder it happens to live in. Used by
# push_document, which (unlike the reverse_sync folder scan) targets an
# arbitrary document identified only by its UUID.
resolve_document_path() {
    local target_uuid=$1 metadata_path id
    : >"$WORK/doc-library.jsonl"
    shopt -s nullglob
    for metadata_path in "$LIBRARY"/*.metadata; do
        id="${metadata_path##*/}"; id="${id%.metadata}"
        if uuid_valid "$id" && "$JQ" -e '
          type=="object" and ([.visibleName,.parent,.type]|all(type=="string"))
          and (.type=="DocumentType" or .type=="CollectionType")' "$metadata_path" >/dev/null; then
            "$JQ" -c --arg id "${id,,}" '{entry:{rm_uuid:$id,title:.visibleName,
              parent:.parent,type:.type,deleted:(.deleted // false)}}' "$metadata_path" >>"$WORK/doc-library.jsonl"
        fi
    done
    "$JQ" -s -f "$ROOT_DIR/scripts/zotbridge-shell-library.jq" "$WORK/doc-library.jsonl" >"$WORK/doc-library.json"
    "$JQ" -e '.ok' "$WORK/doc-library.json" >/dev/null || return 1
    RESOLVED_PATH="$("$JQ" -r --arg uuid "$target_uuid" '
      [.entries[]|select(.rm_uuid==$uuid and .type=="DocumentType")]
      | if length==1 then .[0].path else "" end' "$WORK/doc-library.json")"
    [[ -n $RESOLVED_PATH ]] || return 1
    RESOLVED_NAME="${RESOLVED_PATH##*/}"
}

prepare_reverse_file() {
    local name=$1 base
    base="${name%.pdf}"; base="${base%.PDF}"
    REVERSE_FILENAME="$base.annot.pdf"
    [[ $REVERSE_FILENAME != */* && $REVERSE_FILENAME != *\\* &&
       $REVERSE_FILENAME != *$'\n'* && $REVERSE_FILENAME != *$'\r'* &&
       ${#REVERSE_FILENAME} -le 240 ]] || return 1
    REVERSE_MD5="$(md5sum "$REVERSE_PDF" | cut -d ' ' -f1)"
    REVERSE_MTIME="$(date +%s)000"
    REVERSE_SIZE="$(wc -c <"$REVERSE_PDF")"
}

resolve_reverse_parent() {
    local uuid=$1
    load_state
    "$JQ" -c --arg uuid "$uuid" '.mappings[$uuid] // null' "$WORK/state.json" >"$WORK/reverse-mapping.json"
    REVERSE_NEW_PARENT=false
    if "$JQ" -e '.!=null' "$WORK/reverse-mapping.json" >/dev/null; then
        REVERSE_PARENT="$("$JQ" -r '.zotero_item_key' "$WORK/reverse-mapping.json")"
        reverse_http zotero GET "$API/items/$REVERSE_PARENT" "$WORK/reverse-source.json" || return 1
        [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
        if "$JQ" -e '.data.itemType=="attachment"' "$WORK/reverse-source.json" >/dev/null; then
            REVERSE_PARENT="$("$JQ" -r '.data.parentItem // ""' "$WORK/reverse-source.json")"
        fi
        [[ $REVERSE_PARENT =~ ^[A-Z0-9]{8}$ ]] || return 1
    else
        REVERSE_PARENT="$(reverse_key parent "$uuid")"
        REVERSE_NEW_PARENT=true
    fi
    REVERSE_ATTACHMENT="$(reverse_key attachment "$uuid")"
}

create_reverse_metadata() {
    local uuid=$1 name=$2 collection=${3:-}
    reverse_http zotero GET "$API/items/$REVERSE_ATTACHMENT" "$WORK/existing-attachment.json" || return 1
    if [[ $REVERSE_HTTP_CODE == 200 ]]; then
        "$JQ" -e --arg parent "$REVERSE_PARENT" --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" '
          .data | .itemType=="attachment" and .linkMode=="imported_file"
          and .parentItem==$parent and .filename==$filename and .contentType=="application/pdf"
          and ((.md5 // "")|ascii_downcase)==$md5
          and ((.mtime // "")|tostring|test("^[0-9]{10,13}$"))' \
          "$WORK/existing-attachment.json" >/dev/null || return 1
        REVERSE_MTIME="$("$JQ" -r '.data.mtime|tostring' "$WORK/existing-attachment.json")"
        return
    fi
    [[ $REVERSE_HTTP_CODE == 404 ]] || return 1
    if [[ $REVERSE_NEW_PARENT == true ]]; then
        reverse_http zotero GET "$API/items/$REVERSE_PARENT" "$WORK/existing-parent.json" || return 1
        case "$REVERSE_HTTP_CODE" in
            200)
                "$JQ" -e --arg title "$name" '.data | .itemType=="document" and .title==$title
                  and any(.tags[]?; .tag=="from-rmk")' "$WORK/existing-parent.json" >/dev/null ||
                  return 1
                REVERSE_NEW_PARENT=false
                ;;
            404) ;;
            *) return 1 ;;
        esac
    fi
    "$JQ" -cn --arg parent "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
      --arg title "$name" --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" \
      --arg mtime "$REVERSE_MTIME" --argjson new_parent "$REVERSE_NEW_PARENT" --arg collection "$collection" '
      (if $new_parent then [{key:$parent,version:0,itemType:"document",title:$title,
        creators:[],abstractNote:"",publisher:"",date:"",language:"",shortTitle:"",
        url:"",accessDate:"",archive:"",archiveLocation:"",libraryCatalog:"",
        callNumber:"",rights:"",extra:"",tags:[{tag:"from-rmk"}],
        collections:(if $collection=="" then [] else [$collection] end),relations:{}}]
       else [] end)
      + [{key:$attachment,version:0,itemType:"attachment",parentItem:$parent,
          linkMode:"imported_file",title:$filename,accessDate:"",note:"",tags:[],
          collections:[],relations:{},contentType:"application/pdf",charset:"",
          filename:$filename,md5:$md5,mtime:$mtime}]' >"$WORK/reverse-create.json"
    reverse_http zotero POST "$API/items" "$WORK/reverse-create-response.json" \
      "$WORK/reverse-create.json" application/json || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    "$JQ" -e --arg index "$([[ $REVERSE_NEW_PARENT == true ]] && printf 1 || printf 0)" \
      '.failed=={} and .success[$index]!=null' "$WORK/reverse-create-response.json" >/dev/null
}

upload_reverse_webdav() {
    local force=${1:-false} dav_url="$(get_config webdav_url)" archive="$WORK/$REVERSE_ATTACHMENT.zip"
    reverse_http webdav GET "$dav_url$REVERSE_ATTACHMENT.prop" "$WORK/existing.prop" || return 1
    if [[ $REVERSE_HTTP_CODE == 200 && $force == false ]]; then
        grep -F "<mtime>$REVERSE_MTIME</mtime>" "$WORK/existing.prop" >/dev/null &&
          grep -F "<hash>$REVERSE_MD5</hash>" "$WORK/existing.prop" >/dev/null || return 1
    elif [[ $REVERSE_HTTP_CODE != 200 && $REVERSE_HTTP_CODE != 404 ]]; then
        return 1
    fi
    mkdir -p "$WORK/archive"
    cp -- "$REVERSE_PDF" "$WORK/archive/$REVERSE_FILENAME"
    (cd "$WORK/archive" && "$SEVEN_ZIP" a -tzip "$archive" "$REVERSE_FILENAME" >/dev/null) || return 1
    printf '<properties version="1"><mtime>%s</mtime><hash>%s</hash></properties>' \
      "$REVERSE_MTIME" "$REVERSE_MD5" >"$WORK/$REVERSE_ATTACHMENT.prop"
    reverse_http webdav PUT "$dav_url$REVERSE_ATTACHMENT.zip" "$WORK/webdav-put-zip.out" \
      "$archive" application/zip || return 1
    [[ $REVERSE_HTTP_CODE =~ ^20(0|1|4)$ ]] || return 1
    reverse_http webdav PUT "$dav_url$REVERSE_ATTACHMENT.prop" "$WORK/webdav-put-prop.out" \
      "$WORK/$REVERSE_ATTACHMENT.prop" text/xml || return 1
    [[ $REVERSE_HTTP_CODE =~ ^20(0|1|4)$ ]]
}

verify_reverse_upload() {
    local dav_url="$(get_config webdav_url)"
    reverse_http zotero GET "$API/items/$REVERSE_ATTACHMENT" "$WORK/verify-attachment.json" || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    "$JQ" -e --arg parent "$REVERSE_PARENT" --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" \
      --arg mtime "$REVERSE_MTIME" '.data | .parentItem==$parent and .filename==$filename
      and .contentType=="application/pdf" and ((.md5 // "")|ascii_downcase)==$md5
      and (.mtime|tostring)==$mtime' "$WORK/verify-attachment.json" >/dev/null || return 1
    reverse_http webdav GET "$dav_url$REVERSE_ATTACHMENT.prop" "$WORK/verify.prop" || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    grep -F "<mtime>$REVERSE_MTIME</mtime>" "$WORK/verify.prop" >/dev/null &&
      grep -F "<hash>$REVERSE_MD5</hash>" "$WORK/verify.prop" >/dev/null || return 1
    reverse_http webdav GET "$dav_url$REVERSE_ATTACHMENT.zip" "$WORK/verify.zip" || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    rm -rf "$WORK/verify-dir"; mkdir "$WORK/verify-dir"
    "$SEVEN_ZIP" x -y "-o$WORK/verify-dir" "$WORK/verify.zip" >/dev/null || return 1
    [[ -f "$WORK/verify-dir/$REVERSE_FILENAME" ]] &&
      [[ $(md5sum "$WORK/verify-dir/$REVERSE_FILENAME" | cut -d ' ' -f1) == "$REVERSE_MD5" ]]
}

record_reverse_mapping() {
    local uuid=$1
    "$JQ" -e --arg uuid "$uuid" '.mappings[$uuid] == null' "$WORK/state.json" >/dev/null ||
      return 0
    exec {reverse_state_lock}>>"$STATE.lock"
    flock -n "$reverse_state_lock" || return 1
    load_state
    "$JQ" -L "$ROOT_DIR/scripts" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
      --arg item "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
      --arg path "$REVERSE_FOLDER" --arg uuid "$uuid" '
      include "zotbridge-shell-mapping";
      record_mapping($type;$library;$item;$attachment;$path;$uuid)' \
      "$WORK/state.json" >"$WORK/state-next.json" || return 1
    save_state || return 1
    exec {reverse_state_lock}>&-
}

record_push_mapping() {
    local uuid=$1 path=$2
    exec {push_state_lock}>>"$STATE.lock"
    flock -n "$push_state_lock" || return 1
    load_state
    "$JQ" -L "$ROOT_DIR/scripts" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
      --arg item "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
      --arg path "$path" --arg uuid "$uuid" '
      include "zotbridge-shell-mapping";
      del(.mappings[$uuid]) | record_mapping($type;$library;$item;$attachment;$path;$uuid)' \
      "$WORK/state.json" >"$WORK/state-next.json" || return 1
    save_state || return 1
    exec {push_state_lock}>&-
}

push_verify_parent() {
    reverse_http zotero GET "$API/items/$REVERSE_PARENT" "$WORK/push-parent-check.json" || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    "$JQ" -e '.data.itemType!="attachment" and .data.itemType!="note" and .data.itemType!="annotation"
      and (.data.deleted // false)==false' "$WORK/push-parent-check.json" >/dev/null
}

# Creates or updates the Zotero attachment (and, for a brand-new item, its
# parent) for push_document. Unlike create_reverse_metadata (used by the
# folder-scan reverse_sync), this must also support in-place PDF replacement
# (mode=overwrite) and attaching to a caller-chosen existing item (mode=attach).
create_push_attachment() {
    local mode=$1
    reverse_http zotero GET "$API/items/$REVERSE_ATTACHMENT" "$WORK/push-existing-attachment.json" || return 1
    local existing_code=$REVERSE_HTTP_CODE
    case "$mode" in
        overwrite)
            [[ $existing_code == 200 ]] || return 1
            "$JQ" -e --arg parent "$REVERSE_PARENT" '.data.parentItem==$parent and .data.itemType=="attachment"' \
              "$WORK/push-existing-attachment.json" >/dev/null || return 1
            "$JQ" -c --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" --arg mtime "$REVERSE_MTIME" \
              '[.data | .filename=$filename | .md5=$md5 | .mtime=$mtime]' \
              "$WORK/push-existing-attachment.json" >"$WORK/push-update.json"
            reverse_http zotero POST "$API/items" "$WORK/push-update-response.json" \
              "$WORK/push-update.json" application/json || return 1
            [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
            "$JQ" -e '.failed=={} and .success["0"]!=null' "$WORK/push-update-response.json" >/dev/null
            ;;
        attach)
            if [[ $existing_code == 200 ]]; then
                "$JQ" -e --arg parent "$REVERSE_PARENT" --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" '
                  .data.parentItem==$parent and .data.filename==$filename
                  and ((.data.md5 // "")|ascii_downcase)==$md5' \
                  "$WORK/push-existing-attachment.json" >/dev/null || return 1
                REVERSE_MTIME="$("$JQ" -r '.data.mtime|tostring' "$WORK/push-existing-attachment.json")"
                return 0
            fi
            [[ $existing_code == 404 ]] || return 1
            push_verify_parent || return 1
            "$JQ" -cn --arg attachment "$REVERSE_ATTACHMENT" --arg parent "$REVERSE_PARENT" \
              --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" --arg mtime "$REVERSE_MTIME" '
              [{key:$attachment,version:0,itemType:"attachment",parentItem:$parent,
                linkMode:"imported_file",title:$filename,accessDate:"",note:"",tags:[],
                collections:[],relations:{},contentType:"application/pdf",charset:"",
                filename:$filename,md5:$md5,mtime:$mtime}]' >"$WORK/push-create.json"
            reverse_http zotero POST "$API/items" "$WORK/push-create-response.json" \
              "$WORK/push-create.json" application/json || return 1
            [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
            "$JQ" -e '.failed=={} and .success["0"]!=null' "$WORK/push-create-response.json" >/dev/null
            ;;
        new)
            [[ $existing_code == 404 ]] || return 1
            "$JQ" -cn --arg parent "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
              --arg title "$RESOLVED_NAME" --arg filename "$REVERSE_FILENAME" --arg md5 "$REVERSE_MD5" \
              --arg mtime "$REVERSE_MTIME" --arg collection "$COLLECTION" --args '
              ($ARGS.positional | map({tag:.})) as $extra_tags
              | [{key:$parent,version:0,itemType:"document",title:$title,
                  creators:[],abstractNote:"",publisher:"",date:"",language:"",shortTitle:"",
                  url:"",accessDate:"",archive:"",archiveLocation:"",libraryCatalog:"",
                  callNumber:"",rights:"",extra:"",
                  tags:(($extra_tags + [{tag:"from-rmk"}]) | unique),
                  collections:(if $collection=="" then [] else [$collection] end),relations:{}},
                 {key:$attachment,version:0,itemType:"attachment",parentItem:$parent,
                  linkMode:"imported_file",title:$filename,accessDate:"",note:"",tags:[],
                  collections:[],relations:{},contentType:"application/pdf",charset:"",
                  filename:$filename,md5:$md5,mtime:$mtime}]' -- "${PUSH_TAGS[@]}" >"$WORK/push-create.json"
            reverse_http zotero POST "$API/items" "$WORK/push-create-response.json" \
              "$WORK/push-create.json" application/json || return 1
            [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
            "$JQ" -e '.failed=={} and .success["0"]!=null and .success["1"]!=null' \
              "$WORK/push-create-response.json" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

# Merges the caller-selected reMarkable tags into the parent item's existing
# Zotero tags (attach/overwrite modes only; mode=new embeds tags at creation).
apply_push_tags_to_parent() {
    ((${#PUSH_TAGS[@]})) || return 0
    reverse_http zotero GET "$API/items/$REVERSE_PARENT" "$WORK/push-parent-tags.json" || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    "$JQ" -nc --slurpfile parent "$WORK/push-parent-tags.json" --args '
      ($parent[0].data.tags // []) as $existing
      | ($existing + ($ARGS.positional | map({tag:.}))) | unique' \
      -- "${PUSH_TAGS[@]}" >"$WORK/push-merged-tags.json"
    "$JQ" -ne --slurpfile parent "$WORK/push-parent-tags.json" --slurpfile merged "$WORK/push-merged-tags.json" \
      '($parent[0].data.tags // []) == $merged[0]' >/dev/null && return 0
    "$JQ" -nc --slurpfile parent "$WORK/push-parent-tags.json" --slurpfile merged "$WORK/push-merged-tags.json" \
      '[$parent[0].data | .tags=$merged[0]]' >"$WORK/push-tags-update.json"
    reverse_http zotero POST "$API/items" "$WORK/push-tags-update-response.json" \
      "$WORK/push-tags-update.json" application/json || return 1
    [[ $REVERSE_HTTP_CODE == 200 ]] || return 1
    "$JQ" -e '.failed=={} and .success["0"]!=null' "$WORK/push-tags-update-response.json" >/dev/null
}

push_document() {
    local uuid=$1 mode=$2 parent_key=${3:-}
    [[ $USE_WEBDAV == true && $LIBRARY_TYPE == user ]] ||
      { reverse_fail "$uuid" configuration webdav_required; return 1; }
    [[ -n $RMAPI && -x ${SEVEN_ZIP:-} ]] ||
      { reverse_fail "$uuid" configuration missing_dependency; return 1; }
    for dependency in flock find md5sum sha256sum cut tr cp grep; do
        command -v "$dependency" >/dev/null ||
          { reverse_fail "$uuid" configuration missing_dependency; return 1; }
    done
    reverse_activity started "$uuid"
    resolve_document_path "$uuid" ||
      { reverse_fail "$uuid" locate document_not_found; return 1; }
    export_pdf_from_path "$uuid" "$RESOLVED_NAME" "$RESOLVED_PATH" ||
      { reverse_fail "$uuid" export unsupported_export; return 1; }
    prepare_reverse_file "$RESOLVED_NAME" ||
      { reverse_fail "$uuid" export invalid_filename; return 1; }
    case "$mode" in
        new)
            REVERSE_PARENT="$(reverse_key parent "$uuid")"
            REVERSE_ATTACHMENT="$(reverse_key attachment "$uuid")"
            ;;
        attach)
            REVERSE_PARENT=$parent_key
            REVERSE_ATTACHMENT="$(reverse_key attachment "$uuid:$parent_key")"
            ;;
        overwrite)
            load_state
            "$JQ" -c --arg uuid "$uuid" '.mappings[$uuid] // null' "$WORK/state.json" >"$WORK/push-mapping.json"
            "$JQ" -e '.!=null' "$WORK/push-mapping.json" >/dev/null ||
              { reverse_fail "$uuid" resolve not_mapped; return 1; }
            REVERSE_PARENT="$("$JQ" -r '.zotero_item_key' "$WORK/push-mapping.json")"
            REVERSE_ATTACHMENT="$("$JQ" -r '.zotero_attachment_key' "$WORK/push-mapping.json")"
            [[ $REVERSE_PARENT =~ ^[A-Z0-9]{8}$ && $REVERSE_ATTACHMENT =~ ^[A-Z0-9]{8}$ ]] ||
              { reverse_fail "$uuid" resolve invalid_mapping; return 1; }
            ;;
        *)
            reverse_fail "$uuid" configuration invalid_mode
            return 1
            ;;
    esac
    create_push_attachment "$mode" ||
      { reverse_fail "$uuid" create_attachment metadata_create_failed; return 1; }
    if [[ $mode != new ]]; then
        apply_push_tags_to_parent ||
          { reverse_fail "$uuid" apply_tags tag_update_failed; return 1; }
    fi
    upload_reverse_webdav "$([[ $mode == overwrite ]] && printf true || printf false)" ||
      { reverse_fail "$uuid" upload_zip webdav_upload_failed; return 1; }
    verify_reverse_upload ||
      { reverse_fail "$uuid" verify verification_failed; return 1; }
    record_push_mapping "$uuid" "$RESOLVED_PATH" ||
      { reverse_fail "$uuid" verify mapping_save_failed; return 1; }
    reverse_activity completed "$uuid"
    "$JQ" -cn --arg uuid "$uuid" --arg mode "$mode" --arg parent "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
      '{ok:true,rm_uuid:$uuid,mode:$mode,zotero_item_key:$parent,zotero_attachment_key:$attachment}'
}

move_reverse_document() {
    local uuid=$1 processed="$REVERSE_FOLDER/Copied2Zotero"
    TARGET=$processed
    broker ensureFolder "$processed"
    local processed_uuid=$BROKER_UUID
    broker moveEntry "$uuid,$processed_uuid" optional
    "$JQ" -e --arg parent "$processed_uuid" '.type=="DocumentType" and .deleted!=true
      and .parent==$parent' "$LIBRARY/$uuid.metadata" >/dev/null
}

reverse_item() {
    local uuid=$1 name=$2
    export_reverse_pdf "$uuid" "$name" ||
      { reverse_fail "$uuid" export unsupported_export; return 1; }
    prepare_reverse_file "$name" ||
      { reverse_fail "$uuid" export invalid_filename; return 1; }
    resolve_reverse_parent "$uuid" ||
      { reverse_fail "$uuid" create_parent parent_resolution_failed; return 1; }
    create_reverse_metadata "$uuid" "$name" ||
      { reverse_fail "$uuid" create_attachment metadata_create_failed; return 1; }
    upload_reverse_webdav ||
      { reverse_fail "$uuid" upload_zip webdav_upload_failed; return 1; }
    verify_reverse_upload ||
      { reverse_fail "$uuid" verify verification_failed; return 1; }
    record_reverse_mapping "$uuid" ||
      { reverse_fail "$uuid" verify mapping_save_failed; return 1; }
    move_reverse_document "$uuid" ||
      { reverse_fail "$uuid" move move_failed; return 1; }
    reverse_activity completed "$uuid"
    "$JQ" -cn --arg uuid "$uuid" --arg parent "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
      '{ok:true,rm_uuid:$uuid,zotero_parent_key:$parent,zotero_attachment_key:$attachment}'
}

reverse_sync() {
    [[ $USE_WEBDAV == true && $LIBRARY_TYPE == user ]] ||
      fail configuration_error "Reverse sync requires WebDAV storage for a personal Zotero library."
    [[ -n $RMAPI && -x ${SEVEN_ZIP:-} ]] ||
      fail missing_dependency "Reverse sync requires the bundled rmapi and 7zz binaries."
    for dependency in flock find md5sum sha256sum cut tr cp grep; do
        command -v "$dependency" >/dev/null || fail missing_dependency "Reverse sync requires utility: $dependency."
    done
    exec {reverse_lock}>>"$STATE.reverse.lock"
    flock -n "$reverse_lock" || fail busy "Another reverse sync is running; try later."
    reverse_activity started
    snapshot_reverse_documents
    local total uuid name status copied=0 retained=0
    total="$(wc -l <"$WORK/reverse-documents.jsonl")"
    reverse_activity found "" "" "" "" "$total"
    : >"$WORK/reverse-results.jsonl"
    while IFS=$'\t' read -r uuid name; do
        status=0
        reverse_item "$uuid" "$name" >"$WORK/reverse-one.json" || status=$?
        "$JQ" -c '.' "$WORK/reverse-one.json" >>"$WORK/reverse-results.jsonl"
        if ((status == 0)); then copied=$((copied + 1)); else retained=$((retained + 1)); fi
    done < <("$JQ" -r '[.rm_uuid,.name]|@tsv' "$WORK/reverse-documents.jsonl")
    reverse_activity completed "" "" "" "" "$copied"
    "$JQ" -s --argjson total "$total" --argjson copied "$copied" --argjson retained "$retained" \
      '{ok:($retained==0),total:$total,uploaded:$copied,retained_failures:$retained,results:.}' \
      "$WORK/reverse-results.jsonl"
    return 0
}

sync_all() {
    local reverse_status=0 forward_status=0 forward_target=$TARGET
    reverse_sync >"$WORK/reverse-result.json"
    "$JQ" -e '.ok' "$WORK/reverse-result.json" >/dev/null || reverse_status=1
    TARGET=$forward_target
    sync_tagged >"$WORK/forward-result.json" || forward_status=$?
    "$JQ" -cn --slurpfile reverse "$WORK/reverse-result.json" --slurpfile forward "$WORK/forward-result.json" \
      --argjson reverse_status "$reverse_status" --argjson forward_status "$forward_status" '
      {ok:($reverse_status==0 and $forward_status==0),reverse:$reverse[0],forward:$forward[0],
       synced:($forward[0].synced // 0),skipped:($forward[0].skipped // 0),
       failed:(($forward[0].failed // 0)+($reverse[0].retained_failures // 0))}'
    ((reverse_status == 0 && forward_status == 0))
}
