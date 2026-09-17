def document_uuid:
  type=="string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");

def clear_mappings($library_type; $library):
  if (.mappings | all(.[]; type=="object")) then
    .mappings |= with_entries(select(
      .value.zotero_library_type!=$library_type or .value.zotero_library_id!=$library))
  else error("invalid document mapping record") end;

def require_import_layout:
  if (.mappings | keys | all(.[]; document_uuid))
     and (.attempts | keys | all(.[]; test("^(user|group):[0-9]+$")))
  then . else error("legacy import state requires explicit migration") end;

def mapping_for_item($type; $library; $item):
  require_import_layout
  |
    [.mappings | to_entries[] | select(
      .value.zotero_library_type==$type and .value.zotero_library_id==$library
      and (.value.zotero_item_key==$item or .value.zotero_attachment_key==$item))]
    | if length>1 then error("multiple document mappings for this Zotero item")
      elif length==0 then null
      else .[0] | .value + {rm_uuid:.key} end;

def mapping_for_attachment($library_type; $library; $attachment):
  require_import_layout
  | [.mappings | to_entries[] | select(
      .value.zotero_library_type==$library_type and .value.zotero_library_id==$library
      and .value.zotero_attachment_key==$attachment)]
  | if length>1 then error("multiple document mappings for this Zotero attachment")
    elif length==0 then null else .[0] | .value + {rm_uuid:.key} end;

def import_entry($type; $library; $item; $attachment; $path):
  {zotero_library_type:$type,zotero_library_id:$library,
   zotero_item_key:$item,zotero_attachment_key:$attachment,rm_path:$path,
   updated_at:(now|strftime("%Y-%m-%d %H:%M:%S"))};

def record_attempt($type; $library; $item; $attachment; $path):
  require_import_layout
  | .attempts[$type+":"+$library][$item]=
    (import_entry($type; $library; $item; $attachment; $path) + {state:"uncertain"});

def record_mapping($type; $library; $item; $attachment; $path; $uuid):
  if ($uuid | document_uuid | not) then error("invalid reMarkable document UUID") else . end
  | mapping_for_item($type; $library; $item) as $existing
  | if $existing!=null and $existing.rm_uuid!=$uuid
    then error("Zotero item is already mapped to another document") else . end
  | mapping_for_attachment($type; $library; $attachment) as $attached
  | if $attached!=null and $attached.rm_uuid!=$uuid
    then error("Zotero attachment is already mapped to another document") else . end
  | .mappings[$uuid] as $previous
  | if $previous!=null and (
      $previous.zotero_library_type!=$type or $previous.zotero_library_id!=$library
      or $previous.zotero_item_key!=$item or $previous.zotero_attachment_key!=$attachment)
    then error("document UUID is already linked to another Zotero source") else . end
  | .mappings[$uuid]=(import_entry($type; $library; $item; $attachment; $path) + {state:"imported"})
  | .attempts[$type+":"+$library] = (
      (.attempts[$type+":"+$library] // {}) |
      with_entries(select(.key!=$item and .value.zotero_attachment_key!=$attachment)));
