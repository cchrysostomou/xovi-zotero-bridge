def fail: error("invalid settings draft");
def text: type=="string" and test("[\u0000-\u001f\u007f]")|not;
def tag: text and length>0 and ((contains("||") or startswith("\\-"))|not);
def folder: text and (split("/")|all(gsub("^\\s+|\\s+$";"")|length>0))
  and test("^(?:urn:uuid:)?\\{?[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\\}?$")|not;

def public:
  {ok:true,
   webdav:{enabled:.use_webdav,url:(.webdav_url // ""),username:(.webdav_username // ""),
           password_set:(.webdav_password|type=="string" and length>0)},
   default_target_folder,reverse_sync_folder,sync_queue_tag,sync_synced_tag,list_page_limit};

def apply($draft):
  if ($draft|type!="object" or .version!=1) then fail else . end
  | ($draft|keys - ["version","webdav_url","webdav_username","webdav_password",
      "default_target_folder","reverse_sync_folder","sync_queue_tag","sync_synced_tag",
      "list_page_limit"]) as $unknown
  | if $unknown|length>0 then fail else . end
  | if ($draft.webdav_url|text and test("^https://[^/@?#\\s]+(?:/[^?#\\s]*)?$"))
      and ($draft.webdav_username|text and contains(":")|not)
      and ($draft.default_target_folder|folder)
      and ($draft.reverse_sync_folder|folder)
      and ($draft.sync_queue_tag|tag) and ($draft.sync_synced_tag|tag)
      and $draft.sync_queue_tag != $draft.sync_synced_tag
      and (if $draft|has("webdav_password") then
             .webdav_password|type=="string" and length>0 and text
           else true end)
      and (if $draft|has("list_page_limit") then
             ($draft.list_page_limit|type=="number" and floor==. and .>=1 and .<=100)
           else true end)
    then . else fail end
  | .use_webdav=true
  | .webdav_url=($draft.webdav_url|sub("/+$";"")+"/")
  | .webdav_username=$draft.webdav_username
  | .default_target_folder=$draft.default_target_folder
  | .reverse_sync_folder=$draft.reverse_sync_folder
  | .sync_queue_tag=$draft.sync_queue_tag
  | .sync_synced_tag=$draft.sync_synced_tag
  | if $draft|has("webdav_password") then .webdav_password=$draft.webdav_password else . end
  | if $draft|has("list_page_limit") then .list_page_limit=$draft.list_page_limit else . end;

def toml:
  to_entries | sort_by(.key)[] |
  select(.value | (type=="string" or type=="number" or type=="boolean")) |
  "\(.key) = \(.value|@json)";

if $mode=="public" then public
elif $mode=="apply" then apply($draft[0])
elif $mode=="toml" then toml
else error("invalid settings mode")
end
