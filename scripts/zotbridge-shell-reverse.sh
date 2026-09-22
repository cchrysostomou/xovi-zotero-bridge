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
    local metadata_path content_path uuid
    shopt -s nullglob
    for metadata_path in "$LIBRARY"/*.metadata; do
        uuid="${metadata_path##*/}"; uuid="${uuid%.metadata}"
        uuid_valid "$uuid" || continue
        "$JQ" -e --arg parent "$REVERSE_FOLDER_UUID" '
          .type=="DocumentType" and .deleted!=true and .parent==$parent
          and (.visibleName|type=="string" and length>0)' "$metadata_path" >/dev/null || continue
        content_path="$LIBRARY/$uuid.content"
        # queue_for_zotero stamps the duplicate's own .content.extraMetadata
        # with the original document's uuid and the user's chosen mode/tags/
        # collection at duplicate-creation time; fall back to sane defaults
        # for a document dropped into the folder by hand (no stamping).
        if [[ -f $content_path ]]; then
            "$JQ" -c '.extraMetadata // {}' "$content_path" >"$WORK/reverse-extra.json" || printf '{}' >"$WORK/reverse-extra.json"
        else
            printf '{}' >"$WORK/reverse-extra.json"
        fi
        "$JQ" -c --arg uuid "${uuid,,}" --slurpfile extra "$WORK/reverse-extra.json" '
          {rm_uuid:$uuid,name:.visibleName,
           source_uuid:($extra[0].ZotbridgeSourceUuid // $uuid),
           mode:($extra[0].ZotbridgeMode // "new"),
           annotated_only:(($extra[0].ZotbridgeAnnotatedOnly // "false")=="true"),
           collection:($extra[0].ZotbridgeCollection // ""),
           tags:($extra[0].ZotbridgeTags // "")}' \
          "$metadata_path" >>"$WORK/reverse-documents.jsonl"
    done
}

export_pdf_from_path() {
    local uuid=$1 output="$WORK/export/annotated.pdf"
    rm -rf "$WORK/export"
    mkdir -p "$WORK/export"
    "$LOCALGETA" -library "$LIBRARY" -uuid "$uuid" -output "$output" -a >/dev/null 2>&1 || return 1
    REVERSE_PDF=$output
    pdf_valid "$REVERSE_PDF" || return 1
}

export_reverse_pdf() {
    local uuid=$1
    export_pdf_from_path "$uuid"
}

# Trims $REVERSE_PDF down to only the pages carrying stylus annotations, using
# the rm-librarian/rm-pdfium broker signals (same mechanism as
# xovi-qmd-extensions' duplicateAnnotatedPages.qmd). Replaces $REVERSE_PDF
# with the trimmed copy on success. Returns 1 (no silent fallback) if
# rm-pdfium is unavailable, the broker calls fail, or no annotated pages are
# found, so reverse_item can report a clear error instead of uploading the
# full document.
trim_annotated_pdf() {
    local uuid=$1 content_path="$LIBRARY/$uuid.content" page_range dst
    [[ -f $content_path ]] || return 1
    broker getContentPages "$uuid" text || return 1
    printf '%s' "$BROKER_REPLY" >"$WORK/trim-ids.txt"
    "$JQ" -R -s '[splits("\n")] | map(select(length > 0))' "$WORK/trim-ids.txt" >"$WORK/trim-ids.json"
    "$JQ" -e -r --slurpfile content "$content_path" -f "$ROOT_DIR/scripts/zotbridge-shell-trim-pages.jq" \
      "$WORK/trim-ids.json" >"$WORK/trim-range.txt" 2>/dev/null || return 1
    page_range="$(<"$WORK/trim-range.txt")"
    [[ -n $page_range ]] || return 1
    dst="$WORK/export/annotated.pdf"
    rm -f -- "$dst"
    broker trimPdf "$REVERSE_PDF,$dst,$page_range" text || return 1
    [[ $BROKER_REPLY == ok ]] || return 1
    pdf_valid "$dst" || return 1
    REVERSE_PDF=$dst
}

# Builds a same-name, same-content local duplicate of $src_uuid directly
# inside the known reverse-sync folder (resolve_reverse_folder must already
# have been called), stamping queue_for_zotero's choices into the
# duplicate's own .content.extraMetadata so a later reverse_sync run can act
# on this exact request without any other state being passed back in. Sets
# DUP_UUID/DUP_NAME on success. Only PDF-backed documents are supported (the
# only format rm-pdfium/trimPdf and this feature's export path handle).
duplicate_document() {
    local src_uuid=$1 mode=$2 collection=${3:-} tags_csv=${4:-} annotated_only=$5
    local src_meta src_content src_pdf file_type now new_uuid
    src_meta="$LIBRARY/$src_uuid.metadata"
    src_content="$LIBRARY/$src_uuid.content"
    src_pdf="$LIBRARY/$src_uuid.pdf"
    [[ -f $src_meta && -f $src_content && -f $src_pdf ]] || return 1
    "$JQ" -e '.type=="DocumentType" and (.deleted // false)==false
      and (.visibleName|type=="string" and length>0)' "$src_meta" >/dev/null || return 1
    file_type="$("$JQ" -r '.fileType // ""' "$src_content")"
    [[ $file_type == pdf ]] || return 1
    DUP_NAME="$("$JQ" -r '.visibleName' "$src_meta")"
    new_uuid="$(tr -d '[:space:]' </proc/sys/kernel/random/uuid 2>/dev/null)"
    new_uuid="${new_uuid,,}"
    uuid_valid "$new_uuid" || return 1
    DUP_UUID=$new_uuid
    now="$(date +%s)000"
    "$JQ" -n --arg name "$DUP_NAME" --arg parent "$REVERSE_FOLDER_UUID" --arg now "$now" '
      {createdTime:$now,lastModified:$now,lastOpened:"0",lastOpenedPage:0,
       parent:$parent,pinned:false,type:"DocumentType",visibleName:$name}' \
      >"$LIBRARY/$DUP_UUID.metadata" || return 1
    "$JQ" --arg source "${src_uuid,,}" --arg mode "$mode" --arg collection "$collection" \
      --arg tags "$tags_csv" --arg annotated "$([[ $annotated_only == true ]] && printf true || printf false)" '
      .extraMetadata = ((.extraMetadata // {}) + {
        ZotbridgeSourceUuid:$source, ZotbridgeMode:$mode,
        ZotbridgeCollection:$collection, ZotbridgeTags:$tags,
        ZotbridgeAnnotatedOnly:$annotated})' \
      "$src_content" >"$LIBRARY/$DUP_UUID.content" || return 1
    # Copy every other sibling file/directory that belongs to the source
    # document (.pagedata, the per-page .rm annotation folder, thumbnails,
    # highlights caches, etc.) under the new UUID. .metadata and .content
    # were already built above with source-specific stamped fields, so skip
    # those two. Without .pagedata in particular, rmapi's annotate-merge
    # export can fail to render the duplicate even though the PDF itself is
    # fine, which used to surface as a misleading "file not supported" error.
    local item base suffix
    shopt -s nullglob
    for item in "$LIBRARY/$src_uuid".* "$LIBRARY/$src_uuid"; do
        base="${item##*/}"
        suffix="${base#"$src_uuid"}"
        case "$suffix" in
            .metadata | .content) continue ;;
        esac
        if [[ -d $item ]]; then
            cp -r -- "$item" "$LIBRARY/$DUP_UUID$suffix" || return 1
        else
            cp -- "$item" "$LIBRARY/$DUP_UUID$suffix" || return 1
        fi
    done
    shopt -u nullglob
    broker rescanLibrary "" text
}

# Fast, filesystem-only entry point for the long-press "Send to Zotero"
# action: duplicates $uuid straight into the reverse-sync folder with the
# caller's mode/collection/tags/annotated-only choice stamped onto the
# duplicate, and returns immediately. No network calls and no waiting on
# cloud sync -- the duplicate syncs to the cloud in the background like any
# other document, and a later reverse_sync run (manual, or triggered right
# away by the caller if requested) performs the actual Zotero upload.
queue_for_zotero() {
    local uuid=$1 mode=$2 parent_key=${3:-} collection=${4:-} tags_csv=${5:-} annotated_only=$6
    resolve_reverse_folder
    if [[ $mode == attach ]]; then
        reverse_http zotero GET "$API/items/$parent_key" "$WORK/queue-parent-check.json" ||
            fail state_error "Could not verify the selected Zotero item."
        [[ $REVERSE_HTTP_CODE == 200 ]] ||
            fail ValueError "The selected Zotero item could not be found."
        "$JQ" -e '.data.itemType!="attachment" and .data.itemType!="note" and .data.itemType!="annotation"
          and (.data.deleted // false)==false' "$WORK/queue-parent-check.json" >/dev/null ||
            fail ValueError "The selected Zotero item is not a valid attachment parent."
    fi
    duplicate_document "$uuid" "$mode" "$collection" "$tags_csv" "$annotated_only" ||
        fail state_error "Could not create a local duplicate of that document."
    local dup_uuid=$DUP_UUID dup_name=$DUP_NAME
    if [[ $mode == attach ]]; then
        exec {queue_state_lock}>>"$STATE.lock"
        flock -n "$queue_state_lock" || fail busy "Another operation is using this JSON state; try later."
        load_state
        REVERSE_ATTACHMENT="$(reverse_key attachment "$uuid")"
        "$JQ" -L "$ROOT_DIR/scripts" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
          --arg item "$parent_key" --arg attachment "$REVERSE_ATTACHMENT" \
          --arg path "$REVERSE_FOLDER" --arg uuid "$uuid" '
          include "zotbridge-shell-mapping";
          del(.mappings[$uuid]) | record_mapping($type;$library;$item;$attachment;$path;$uuid)' \
          "$WORK/state.json" >"$WORK/state-next.json" ||
            fail state_error "Could not save the Zotero mapping."
        save_state || fail state_error "Could not save the Zotero mapping."
        exec {queue_state_lock}>&-
    fi
    "$JQ" -cn --arg uuid "$uuid" --arg dup_uuid "$dup_uuid" --arg name "$dup_name" --arg mode "$mode" \
      '{ok:true,rm_uuid:$uuid,duplicate_uuid:$dup_uuid,name:$name,mode:$mode,queued_folder:true}'
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
    local uuid=$1 name=$2 collection=${3:-} tags_csv=${4:-}
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
      --arg mtime "$REVERSE_MTIME" --argjson new_parent "$REVERSE_NEW_PARENT" --arg collection "$collection" \
      --arg tags_csv "$tags_csv" '
      ($tags_csv | if .=="" then [] else split(",") end | map({tag:.})) as $extra_tags
      | (if $new_parent then [{key:$parent,version:0,itemType:"document",title:$title,
        creators:[],abstractNote:"",publisher:"",date:"",language:"",shortTitle:"",
        url:"",accessDate:"",archive:"",archiveLocation:"",libraryCatalog:"",
        callNumber:"",rights:"",extra:"",tags:(($extra_tags + [{tag:"from-rmk"}]) | unique),
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
    local uuid=$1 name=$2 source_uuid=$3 annotated_only=$4 collection=${5:-} tags_csv=${6:-}
    export_reverse_pdf "$uuid" ||
      { reverse_fail "$source_uuid" export unsupported_export; return 1; }
    if [[ $annotated_only == true ]]; then
        trim_annotated_pdf "$uuid" ||
          { reverse_fail "$source_uuid" export annotations_only_unavailable; return 1; }
    fi
    prepare_reverse_file "$name" ||
      { reverse_fail "$source_uuid" export invalid_filename; return 1; }
    resolve_reverse_parent "$source_uuid" ||
      { reverse_fail "$source_uuid" create_parent parent_resolution_failed; return 1; }
    create_reverse_metadata "$source_uuid" "$name" "$collection" "$tags_csv" ||
      { reverse_fail "$source_uuid" create_attachment metadata_create_failed; return 1; }
    upload_reverse_webdav ||
      { reverse_fail "$source_uuid" upload_zip webdav_upload_failed; return 1; }
    verify_reverse_upload ||
      { reverse_fail "$source_uuid" verify verification_failed; return 1; }
    record_reverse_mapping "$source_uuid" ||
      { reverse_fail "$source_uuid" verify mapping_save_failed; return 1; }
    move_reverse_document "$uuid" ||
      { reverse_fail "$source_uuid" move move_failed; return 1; }
    reverse_activity completed "$source_uuid"
    "$JQ" -cn --arg uuid "$source_uuid" --arg parent "$REVERSE_PARENT" --arg attachment "$REVERSE_ATTACHMENT" \
      '{ok:true,rm_uuid:$uuid,zotero_parent_key:$parent,zotero_attachment_key:$attachment}'
}

reverse_sync() {
    [[ $USE_WEBDAV == true && $LIBRARY_TYPE == user ]] ||
      fail configuration_error "Reverse sync requires WebDAV storage for a personal Zotero library."
    [[ -n $LOCALGETA && -x ${SEVEN_ZIP:-} ]] ||
      fail missing_dependency "Reverse sync requires the bundled zotbridge-localgeta and 7zz binaries."
    for dependency in flock find md5sum sha256sum cut tr cp grep; do
        command -v "$dependency" >/dev/null || fail missing_dependency "Reverse sync requires utility: $dependency."
    done
    exec {reverse_lock}>>"$STATE.reverse.lock"
    flock -n "$reverse_lock" || fail busy "Another reverse sync is running; try later."
    reverse_activity started
    snapshot_reverse_documents
    local total uuid name source_uuid annotated_only collection tags status copied=0 retained=0
    total="$(wc -l <"$WORK/reverse-documents.jsonl")"
    reverse_activity found "" "" "" "" "$total"
    : >"$WORK/reverse-results.jsonl"
    while IFS=$'\t' read -r uuid name source_uuid annotated_only collection tags; do
        status=0
        reverse_item "$uuid" "$name" "$source_uuid" "$annotated_only" "$collection" "$tags" \
          >"$WORK/reverse-one.json" || status=$?
        "$JQ" -c '.' "$WORK/reverse-one.json" >>"$WORK/reverse-results.jsonl"
        if ((status == 0)); then copied=$((copied + 1)); else retained=$((retained + 1)); fi
    done < <("$JQ" -r '[.rm_uuid,.name,.source_uuid,.annotated_only,.collection,.tags]|@tsv' "$WORK/reverse-documents.jsonl")
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
