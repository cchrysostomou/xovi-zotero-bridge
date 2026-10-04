# Flat TOML only. Error messages identify fields/lines but never contain values.
def checked($field; $condition):
  if $condition then . else error("Invalid setting: " + $field) end;
def text: type == "string" and (test("[\u0000-\u001f\u007f]") | not);
def positive_timeout: type == "number" and . > 0 and . <= 300;
def size_limit: type == "number" and floor == . and . >= 1 and . <= 2048;
def parse:
  reduce (split("\n") | to_entries[]
    | .value |= sub("\r$"; "")
    | select(.value | test("^\\s*(#.*)?$") | not)) as $line
    ({};
     ($line.value | capture("^\\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(?<value>\"(?:[^\"\\\\\\x00-\\x1f]|\\\\.)*\"|true|false|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\\s*(?:#.*)?$")
       // error("Invalid configuration syntax on line \($line.key + 1). Use key = value with double-quoted strings; no sections or multiline values.")) as $pair
     | checked("duplicate key on line \($line.key + 1)"; has($pair.key) | not)
     | .[$pair.key] = (try ($pair.value | fromjson)
         catch error("Invalid string escape on line \($line.key + 1). Use JSON-compatible double-quoted strings.")));
def defaults:
  .library_id = (.library_id // "")
  | .library_type = (.library_type // "")
  | .api_key = (.api_key // "")
  | .use_webdav = (.use_webdav // false)
  | .webdav_allow_http = (.webdav_allow_http // false)
  | .broker_timeout_s = (.broker_timeout_s // 30)
  | .webdav_timeout_s = (.webdav_timeout_s // 60)
  | .zotero_timeout_s = (.zotero_timeout_s // 60)
  | .webdav_max_download_mb = (.webdav_max_download_mb // 100)
  | .zotero_max_download_mb = (.zotero_max_download_mb // 100)
  | .mb_in_path = (.mb_in_path // "/run/xovi-mb")
  | .mb_out_path = (.mb_out_path // "/run/xovi-mb-out")
  | .state_db_path = (.state_db_path // "./zotbridge-state.db")
  | .state_json_path = (.state_json_path // ((.state_db_path|tostring) + ".json"))
  | .default_target_folder = (.default_target_folder // "Zotero/unread")
  | .reverse_sync_folder = (.reverse_sync_folder // "Zotero/Read")
  | .sync_queue_tag = (.sync_queue_tag // "to_sync")
  | .sync_synced_tag = (.sync_synced_tag // "synced")
  | .list_page_limit = (.list_page_limit // 8)
  | .list_cache_ttl_s = (.list_cache_ttl_s // 86400)
  | .xochitl_dir = (.xochitl_dir // env.XOCHITL_DIR // "/home/root/.local/share/remarkable/xochitl");
def validate:
  checked("library_id (numeric Zotero user/group ID required)"; .library_id | type == "number" or type == "string")
  | .library_id |= tostring
  | checked("library_id (digits only)"; .library_id | test("^[0-9]+$"))
  | checked("library_type (user or group)"; .library_type == "user" or .library_type == "group")
  | checked("api_key (required; no control characters)"; .api_key | text and length > 0)
  | checked("use_webdav (true or false)"; .use_webdav | type == "boolean")
  | checked("webdav_allow_http (true or false)"; .webdav_allow_http | type == "boolean")
  | checked("broker_timeout_s (greater than 0, at most 300)"; .broker_timeout_s | positive_timeout)
  | checked("webdav_timeout_s (greater than 0, at most 300)"; .webdav_timeout_s | positive_timeout)
  | checked("zotero_timeout_s (greater than 0, at most 300)"; .zotero_timeout_s | positive_timeout)
  | checked("webdav_max_download_mb (integer 1-2048)"; .webdav_max_download_mb | size_limit)
  | checked("zotero_max_download_mb (integer 1-2048)"; .zotero_max_download_mb | size_limit)
  | checked("list_page_limit (integer 1-100)"; .list_page_limit | type == "number" and floor == . and . >= 1 and . <= 100)
  | checked("list_cache_ttl_s (nonnegative integer)"; .list_cache_ttl_s | type == "number" and floor == . and . >= 0)
  | reduce ["default_target_folder","reverse_sync_folder"][] as $key (.;
      checked($key + " (folder path, not UUID; no empty components)";
        .[$key] | text and (split("/") | all(gsub("^\\s+|\\s+$";"") | length>0))
        and (test("^(?:urn:uuid:)?\\{?[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\\}?$") | not)))
  | reduce ["sync_queue_tag","sync_synced_tag"][] as $key (.;
      checked($key + " (nonempty literal tag)"; .[$key] | text and length>0
        and ((contains("||") or startswith("\\-") or test("[\u0000-\u001f\u007f]")) | not)))
  | checked("sync_synced_tag (must differ from sync_queue_tag)"; .sync_queue_tag != .sync_synced_tag)
  | reduce ["mb_in_path","mb_out_path","state_db_path","state_json_path","xochitl_dir"][] as $key (.;
      checked($key + " (nonempty path)"; .[$key] | text and length > 0))
  | if .use_webdav then
      checked("library_type (WebDAV supports user libraries only)"; .library_type == "user")
      | reduce ["webdav_url","webdav_username","webdav_password"][] as $key (.;
          checked($key + " (required for WebDAV)"; .[$key] | text and (gsub("^\\s+|\\s+$"; "") | length > 0)))
      | checked("webdav_username (must not contain a colon)"; .webdav_username | contains(":") | not)
      | checked("webdav_url (HTTP(S) directory URL without embedded credentials, query or fragment)";
          .webdav_url | test("^https?://[^/@?#\\s]+(?:/[^?#\\s]*)?$"))
      | checked("webdav_url (HTTPS required unless webdav_allow_http is explicitly true)";
          (.webdav_url | startswith("https://")) or .webdav_allow_http)
      | .webdav_url |= (sub("/+$"; "") + "/")
    else . end;

($ARGS.named.config_mode // "validate") as $mode
| if $mode == "report" or $mode == "setup-report" then
    try (parse | defaults
      | if $mode == "setup-report" then
          . as $cfg | (try (validate | {configured:true,message:""}) catch {configured:false,message:.}) as $status
          | {ok:true,config:$cfg} + $status
        else validate | {ok:true,config:.,configured:true} end)
    catch {ok:false,message:.}
  else parse | defaults | validate end
