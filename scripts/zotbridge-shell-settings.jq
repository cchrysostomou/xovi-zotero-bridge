def fail($field): error("Invalid setting: " + $field);
def text: type=="string" and (test("[\u0000-\u001f\u007f]")|not);
def tag: text and length>0 and ((contains("||") or startswith("\\-"))|not);
def folder: text and (split("/")|all(gsub("^\\s+|\\s+$";"")|length>0))
  and (test("^(?:urn:uuid:)?\\{?[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\\}?$")|not);

def public:
  {ok:true,
   configured:(if $ARGS.named|has("configured") then $ARGS.named.configured else true end),
   configuration_message:($ARGS.named.configuration_message // ""),
   zotero:{library_id:(.library_id|tostring),library_type:.library_type,
           api_key_set:(.api_key|type=="string" and length>0)},
   webdav:{enabled:.use_webdav,url:(.webdav_url // ""),username:(.webdav_username // ""),
           password_set:(.webdav_password|type=="string" and length>0)},
   default_target_folder,reverse_sync_folder,sync_queue_tag,sync_synced_tag,list_page_limit};

def apply($draft):
  if ($draft|type!="object" or .version!=1) then fail("draft version (expected 1)") else . end
  | ($draft|keys - ["version","webdav_url","webdav_username","webdav_password",
      "default_target_folder","reverse_sync_folder","sync_queue_tag","sync_synced_tag",
      "list_page_limit","library_id","library_type","api_key","use_webdav"]) as $unknown
  | if $unknown|length>0 then fail("draft contains unsupported fields") else . end
  | reduce ["default_target_folder","reverse_sync_folder"][] as $key (.;
      if ($draft[$key]|folder) then . else fail($key + " (folder path, not UUID)") end)
  | reduce ["sync_queue_tag","sync_synced_tag"][] as $key (.;
      if ($draft[$key]|tag) then . else fail($key + " (nonempty literal tag)") end)
  | if $draft.sync_queue_tag == $draft.sync_synced_tag then fail("sync_synced_tag (must differ from sync_queue_tag)") else . end
  | reduce ["api_key","webdav_password"][] as $key (.;
      if ($draft|has($key)) then
        if ($draft[$key]|text and length>0) then . else fail($key + " (nonempty replacement required)") end
      else . end)
  | if ($draft|has("list_page_limit")) and
       (($draft.list_page_limit|type=="number" and floor==. and .>=1 and .<=100)|not)
    then fail("list_page_limit (integer 1-100)") else . end
  | reduce ["library_id","library_type","api_key","use_webdav",
            "webdav_url","webdav_username","webdav_password"][] as $key (.;
      if $draft|has($key) then .[$key]=$draft[$key] else . end)
  | .default_target_folder=$draft.default_target_folder
  | .reverse_sync_folder=$draft.reverse_sync_folder
  | .sync_queue_tag=$draft.sync_queue_tag
  | .sync_synced_tag=$draft.sync_synced_tag
  | if $draft|has("list_page_limit") then .list_page_limit=$draft.list_page_limit else . end;

def toml:
  to_entries | sort_by(.key)[] |
  select(.value | (type=="string" or type=="number" or type=="boolean")) |
  "\(.key) = \(.value|@json)";

if $mode=="public" then public
elif $mode=="apply" then
  try (apply($draft[0]) | {ok:true,config:.}) catch {ok:false,message:.}
elif $mode=="toml" then toml
else error("invalid settings mode")
end
