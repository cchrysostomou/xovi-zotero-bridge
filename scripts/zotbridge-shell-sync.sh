#!/usr/bin/env bash
# Shared by the shell import and sync commands; sourced after runtime setup.

begin_import() {
    validate_target_folder
    lock_state
    local state_lock="${SQLITE_STATE%.*}.lock"
    [[ ${SQLITE_STATE##*/} == *.* ]] || state_lock="$SQLITE_STATE.lock"
    mkdir -p -- "$(dirname -- "$state_lock")"
    exec {import_lock}>>"$state_lock"
    flock -n "$import_lock" || fail busy "Another bridge import is running; try later."
    load_state
}

resolve_attachment() {
    metadata "items/$ITEM_KEY" "$WORK/item.json"
    "$JQ" -e --arg key "$ITEM_KEY" '.data.key==$key and (.data.itemType|type=="string")' \
      "$WORK/item.json" >/dev/null || fail zotero_error "Invalid source item metadata."
    case "$("$JQ" -r '.data.itemType' "$WORK/item.json")" in
        attachment)
            "$JQ" -e '.data | .contentType=="application/pdf" and
              (.linkMode=="imported_file" or .linkMode=="imported_url")' "$WORK/item.json" >/dev/null ||
              fail unsupported_item "The tagged attachment must be a stored PDF, not a linked file or URL."
            ATTACHMENT=$ITEM_KEY ;;
        note|annotation) fail unsupported_item "Tag a reference or stored PDF attachment, not a note or annotation." ;;
        *) find_attachment "$ITEM_KEY" ;;
    esac
    [[ -n $ATTACHMENT ]] || fail no_pdf "No stored PDF attachment found for the reference."
}

load_attachment_filename() {
    metadata "items/$ATTACHMENT" "$WORK/attachment.json"
    "$JQ" -e --arg key "$ATTACHMENT" '.data.key==$key and
      (.data.filename|type=="string" and length>0 and
        (test("[\u0000-\u001f\u007f]") | not))' "$WORK/attachment.json" >/dev/null ||
      fail zotero_error "Zotero returned invalid PDF attachment metadata."
    ZOTERO_FILENAME="$("$JQ" -r '.data.filename' "$WORK/attachment.json")"
}

verify_mapped_document() {
    local uuid parent depth=0
    uuid="$("$JQ" -r '.rm_uuid' "$WORK/mapping.json")"
    "$JQ" -e '.state=="imported"' "$WORK/mapping.json" >/dev/null &&
      "$JQ" -e '.type=="DocumentType" and .deleted!=true and (.parent|type=="string")' \
        "$LIBRARY/$uuid.metadata" >/dev/null &&
      "$JQ" -e '.fileType=="pdf"' "$LIBRARY/$uuid.content" >/dev/null &&
      pdf_valid "$LIBRARY/$uuid.pdf" ||
      fail verification_error "The mapped reMarkable PDF is missing, deleted or invalid; its Zotero tag was not changed."
    parent="$("$JQ" -r '.parent' "$LIBRARY/$uuid.metadata")"
    while [[ -n $parent ]]; do
        ((depth < 200)) && uuid_valid "$parent" &&
          "$JQ" -e '.type=="CollectionType" and .deleted!=true and (.parent|type=="string")' \
            "$LIBRARY/$parent.metadata" >/dev/null ||
          fail verification_error "The mapped document is in trash or an unreadable/cyclic folder hierarchy; its Zotero tag was not changed."
        parent="$("$JQ" -r '.parent' "$LIBRARY/$parent.metadata")"
        depth=$((depth + 1))
    done
}

import_selected_pdf() {
    find_mapping
    if "$JQ" -e --arg attachment "$ATTACHMENT" \
      '.!=null and .zotero_attachment_key!=$attachment' "$WORK/mapping.json" >/dev/null; then
        fail source_changed "This source was previously imported with a different PDF. Inspect its mapping before importing again."
    fi
    "$JQ" -L "$ROOT_DIR/scripts" --arg type "$LIBRARY_TYPE" --arg library "$LIBRARY_ID" \
      --arg attachment "$ATTACHMENT" 'include "zotbridge-shell-mapping";
      mapping_for_attachment($type; $library; $attachment)' "$WORK/state.json" >"$WORK/mapping.json" ||
      fail state_error "Conflicting attachment mappings require explicit repair."
    if "$JQ" -e '.!=null' "$WORK/mapping.json" >/dev/null; then
        [[ $COMMAND != sync-item ]] || verify_mapped_document
        "$JQ" --arg key "$ITEM_KEY" '{ok:true,already_imported:true,item_key:$key,
          attachment_key:.zotero_attachment_key,rm_uuid:.rm_uuid,rm_path:.rm_path}' \
          "$WORK/mapping.json" >"$WORK/import-result.json"
        [[ $COMMAND == sync-item ]] || "$JQ" '.' "$WORK/import-result.json"
        return
    fi
    if [[ $RETRY != true ]] && "$JQ" -e --arg scope "$LIBRARY_SCOPE" --arg key "$ITEM_KEY" \
      --arg attachment "$ATTACHMENT" '.attempts[$scope] // {} | to_entries |
      any(.[]; .key==$key or .value.zotero_attachment_key==$attachment)' "$WORK/state.json" >/dev/null; then
        fail import_uncertain "This item or PDF has an unconfirmed import. Inspect the tablet before explicitly retrying; sync never retries uncertain imports."
    fi
    download_pdf
    [[ $PDF_PATH != *,* && $PDF_PATH != *$'\n'* && $PDF_PATH != *$'\r'* ]] ||
        fail ValueError "The absolute import path cannot contain a comma or newline. Choose a different ZOTBRIDGE_WORK_DIR."
    broker ensureFolder "$TARGET"
    FOLDER_UUID=$BROKER_UUID
    state_record attempt
    broker importDocument "$PDF_PATH,$FOLDER_UUID"
    DOCUMENT_UUID=$BROKER_UUID
    "$JQ" -e --arg parent "$FOLDER_UUID" '.type=="DocumentType" and .parent==$parent and .deleted!=true' \
      "$LIBRARY/$DOCUMENT_UUID.metadata" >/dev/null &&
      "$JQ" -e '.fileType=="pdf"' "$LIBRARY/$DOCUMENT_UUID.content" >/dev/null &&
      pdf_valid "$LIBRARY/$DOCUMENT_UUID.pdf" &&
      [[ $(wc -c < "$LIBRARY/$DOCUMENT_UUID.pdf") -eq $(wc -c < "$PDF_PATH") ]] ||
      fail verification_error "Imported document metadata/content/PDF did not match the expected destination; import remains uncertain."
    state_record mapping
    "$JQ" -cn --arg item "$ITEM_KEY" --arg attachment "$ATTACHMENT" --arg uuid "$DOCUMENT_UUID" --arg path "$TARGET" \
      '{ok:true,already_imported:false,item_key:$item,attachment_key:$attachment,rm_uuid:$uuid,rm_path:$path}' \
      >"$WORK/import-result.json"
    [[ $COMMAND == sync-item ]] || "$JQ" '.' "$WORK/import-result.json"
}

apply_source_tags() {
    local tags payload
    # Every import always carries these two fixed marker tags, in addition to
    # the source's own non-queue Zotero tags.
    "$JQ" -c --arg queue "$QUEUE_TAG" \
      '[.data.tags[].tag | select(.!=$queue)] + ["zotero-import","unread"] | unique' \
      "$WORK/item.json" >"$WORK/source-tags.json"
    "$JQ" -c --slurpfile source "$WORK/source-tags.json" '
      [(.tags // [])[], $source[0][]] | unique' \
      "$LIBRARY/$DOCUMENT_UUID.metadata" >"$WORK/remarkable-tags.json" ||
      fail tag_verification_error "The imported document metadata could not be read before setting its tags."
    "$JQ" -e '
      all(.[]; type=="string" and length>0
          and (contains(";") or contains(",") or test("[\u0000-\u001f\u007f]") | not))' \
      "$WORK/remarkable-tags.json" >/dev/null ||
      fail unsupported_tag "A tag cannot be represented through rm-librarian because it is empty or contains a comma, semicolon, or control character."
    tags="$("$JQ" -c '.tags // [] | unique' "$LIBRARY/$DOCUMENT_UUID.metadata")" ||
      fail tag_verification_error "The imported document metadata could not be read before setting its tags."
    [[ $tags != "$(<"$WORK/remarkable-tags.json")" ]] || return 0
    payload="$("$JQ" -r 'join(";")' "$WORK/remarkable-tags.json")"
    broker setTags "$DOCUMENT_UUID,$payload" optional
    [[ $BROKER_REPLY == ok ]] ||
      fail tag_update_error "rm-librarian did not confirm the reMarkable tag update."
}

validate_sync_tags() {
    "$JQ" -ne --arg queue "$QUEUE_TAG" --arg done "$SYNCED_TAG" '
      $queue!=$done and ([$queue,$done] | all(.[];
        length>0 and ((contains("||") or startswith("\\-") or test("[\u0000-\u001f\u007f]")) | not)))' >/dev/null ||
      fail ValueError "Sync tags must be distinct, nonempty literal names without controls, '||', or a leading backslash-hyphen."
}

validate_sync_source() {
    "$JQ" -e --arg key "$ITEM_KEY" '.data.key==$key
      and (.version|type=="number" and .>=0 and floor==.)
      and (.data.tags|type=="array" and all(.[]; type=="object" and (.tag|type=="string")))' \
      "$WORK/item.json" >/dev/null || fail zotero_error "Zotero returned invalid source tags or item version."
}

mark_source_synced() {
    local expected=$ATTACHMENT attempt version
    for ((attempt=0; attempt<3; attempt++)); do
        resolve_attachment
        validate_sync_source
        [[ $ATTACHMENT == "$expected" ]] ||
          fail source_changed "The reference now selects a different PDF; its tag was not changed."
        if ! "$JQ" -e --arg tag "$QUEUE_TAG" 'any(.data.tags[]; .tag==$tag)' "$WORK/item.json" >/dev/null; then
            "$JQ" -e --arg tag "$SYNCED_TAG" 'any(.data.tags[]; .tag==$tag)' "$WORK/item.json" >/dev/null ||
              fail source_changed "The queue tag was removed elsewhere; the bridge did not add a completion tag."
            TAG_UPDATED=false
            return
        fi
        version="$("$JQ" -r '.version' "$WORK/item.json")"
        "$JQ" --arg queue "$QUEUE_TAG" --arg done "$SYNCED_TAG" '
          {tags:(.data.tags | map(select(.tag!=$queue)) |
            if any(.[]; .tag==$done) then . else .+[{tag:$done,type:0}] end)}' \
          "$WORK/item.json" >"$WORK/tag-patch.json"
        request zotero "$API/items/$ITEM_KEY" "$WORK/patch-response" 8388608 "$ZOTERO_TIMEOUT" \
          PATCH "$WORK/tag-patch.json" "$version"
        case "$HTTP_CODE" in
            204) TAG_UPDATED=true; return ;;
            412) continue ;;
            401|403) fail write_permission "Zotero rejected tag writeback. Enable write access for this library; the imported PDF mapping is retained." ;;
            *) fail zotero_write_error "Zotero tag update returned HTTP $HTTP_CODE. The imported PDF mapping is retained; rerun sync after resolving the error." ;;
        esac
    done
    fail write_conflict "The Zotero item kept changing during tag updates. Its import mapping is retained; retry later."
}

sync_item() {
    validate_sync_tags
    begin_import
    metadata "items/$ITEM_KEY" "$WORK/item.json"
    validate_sync_source
    if ! "$JQ" -e --arg tag "$QUEUE_TAG" 'any(.data.tags[]; .tag==$tag)' "$WORK/item.json" >/dev/null; then
        "$JQ" -cn --arg key "$ITEM_KEY" '{ok:true,item_key:$key,skipped:true,reason:"queue_tag_absent"}'
        return
    fi
    resolve_attachment
    load_attachment_filename
    activity_event hit "" "$QUEUE_TAG" "" "$ITEM_KEY" "$ZOTERO_FILENAME"
    import_selected_pdf
    DOCUMENT_UUID="$("$JQ" -r '.rm_uuid' "$WORK/import-result.json")"
    mark_source_synced
    REMARKABLE_TAGS_UPDATED=false
    REMARKABLE_TAGS_ERROR=
    if (apply_source_tags) >"$WORK/tag-result.json"; then
        REMARKABLE_TAGS_UPDATED=true
    else
        REMARKABLE_TAGS_ERROR="$("$JQ" -r '.error // "tag_update_error"' "$WORK/tag-result.json" 2>/dev/null ||
          printf '%s' tag_update_error)"
    fi
    "$JQ" --argjson changed "$TAG_UPDATED" --argjson tags_updated "$REMARKABLE_TAGS_UPDATED" \
      --arg tags_error "$REMARKABLE_TAGS_ERROR" '
      .+{skipped:false,tag_updated:$changed,remarkable_tags_updated:$tags_updated}
      + (if $tags_error=="" then {} else {remarkable_tags_error:$tags_error} end)' \
      "$WORK/import-result.json"
}

snapshot_sync_queue() {
    local start=0 count total=-1 version= current_version encoded_tag
    encoded_tag="$(printf '%s' "$QUEUE_TAG" | "$JQ" -Rrs 'if startswith("-") then "\\"+. else . end | @uri')"
    : >"$WORK/queue.jsonl"
    while :; do
        # Enumerate both parents and attachments, before our first tag mutation.
        metadata "items?limit=100&start=$start&tag=$encoded_tag&sort=dateAdded&direction=asc" "$WORK/queue-page.json"
        total_results
        current_version="$("$JQ" -Rse '[split("\n")[] |
          select(test("^Last-Modified-Version:";"i")) |
          capture("^Last-Modified-Version:[ \t]*(?<v>[0-9]+)[ \t\r]*$";"i").v] |
          last // error("missing library version")' "$WORK/headers")" ||
          fail zotero_error "Zotero omitted the library version required for queue pagination."
        if ((total < 0)); then total=$TOTAL_RESULTS; version=$current_version; fi
        [[ $version == "$current_version" && $total == "$TOTAL_RESULTS" ]] ||
          fail queue_changed "The Zotero library changed during queue pagination. No items were imported; rerun sync."
        ((total <= 10000)) || fail queue_limit "More than 10000 tagged sources; reduce the queue before syncing."
        "$JQ" -e 'type=="array" and length<=100 and all(.[];
          .key==.data.key and (.key|type=="string" and test("^[A-Z0-9]{8}$")))' \
          "$WORK/queue-page.json" >/dev/null || fail zotero_error "Invalid sync queue page."
        count="$("$JQ" 'length' "$WORK/queue-page.json")"
        "$JQ" -c '.[]|.key' "$WORK/queue-page.json" >>"$WORK/queue.jsonl"
        start=$((start + count))
        ((start < total)) || break
        ((count > 0)) || fail zotero_error "Empty page before the end of the sync queue."
    done
    "$JQ" -se --argjson total "$total" 'length==$total and (unique|length)==$total' \
      "$WORK/queue.jsonl" >/dev/null ||
      fail queue_changed "The sync queue contained missing or repeated items. No items were imported; rerun sync."
}

sync_tagged() {
    validate_sync_tags
    validate_target_folder
    mkdir -p -- "$(dirname -- "$STATE")"
    exec {batch_lock}>>"$STATE.sync.lock"
    flock -n "$batch_lock" || fail busy "Another tagged sync is running; try later."
    load_state
    activity_event started "" "$QUEUE_TAG"
    snapshot_sync_queue
    local key result stop=false found downloaded
    found="$(wc -l <"$WORK/queue.jsonl")"
    activity_event found "" "$QUEUE_TAG" "$found"
    : >"$WORK/results.jsonl"
    : >"$WORK/remaining.jsonl"
    while IFS= read -r key; do
        if [[ $stop == true ]]; then printf '%s\n' "$key" >>"$WORK/remaining.jsonl"; continue; fi
        key="$(printf '%s' "$key" | "$JQ" -r '.')"
        ZOTBRIDGE_ACTIVITY_CHILD=true ZOTBRIDGE_ACTIVITY_PARENT_ACTION="$COMMAND" \
          bash "$ROOT_DIR/scripts/zotbridge-shell.sh" sync-item --item-key "$key" \
          --tag "$QUEUE_TAG" --synced-tag "$SYNCED_TAG" --target-folder "$TARGET" \
          >"$WORK/one-result.json" &
        WORKER=$!
        WORKER_IS_COMMAND=true
        result=0
        wait "$WORKER" || result=$?
        WORKER=
        WORKER_IS_COMMAND=false
        "$JQ" -se --argjson status "$result" 'length==1 and (.[0] |
          type=="object" and (.ok|type=="boolean") and .ok==($status==0))' "$WORK/one-result.json" >/dev/null ||
          fail runtime_error "The sync worker returned an invalid result. Check item status before retrying."
        "$JQ" -c --arg key "$key" '.+{item_key:$key}' "$WORK/one-result.json" >>"$WORK/results.jsonl"
        # Abort on shared infrastructure failures; item-specific failures can continue.
        if ((result != 0)) && "$JQ" -e '.error |
          IN("unsupported_item","unsupported_tag","archive_error","download_error",
             "no_pdf","source_changed","write_conflict","verification_error") | not' \
          "$WORK/one-result.json" >/dev/null; then stop=true; fi
        [[ ! -e $MB_IN.zotbridge-pending ]] || stop=true
    done <"$WORK/queue.jsonl"
    "$JQ" -s --slurpfile remaining "$WORK/remaining.jsonl" '
      {ok:(all(.[]; .ok) and ($remaining|length)==0),
       total:(length+($remaining|length)),processed:length,
       synced:([.[]|select(.ok and .skipped!=true)]|length),
       skipped:([.[]|select(.skipped==true)]|length),
       failed:([.[]|select(.ok==false)]|length),remaining:$remaining,results:.}' \
      "$WORK/results.jsonl" >"$WORK/batch-result.json"
    downloaded="$("$JQ" '[.results[] | select(.ok and .skipped!=true and .already_imported==false)] | length' \
      "$WORK/batch-result.json")"
    activity_event downloaded "" "$QUEUE_TAG" "$downloaded"
    "$JQ" '.' "$WORK/batch-result.json"
    "$JQ" -e '.ok' "$WORK/batch-result.json" >/dev/null
}
