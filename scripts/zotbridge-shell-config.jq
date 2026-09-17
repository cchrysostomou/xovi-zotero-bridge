# Supported TOML subset: flat bare keys and JSON-compatible double-quoted
# strings, numbers and booleans. Blank lines, comments and CRLF are accepted.
# Reject tables, multiline/literal strings, duplicate keys and control bytes.
def checked($condition):
  if $condition then . else error("invalid configuration") end;
def text: type == "string" and (test("[\u0000-\u001f\u007f]") | not);
def positive_timeout: type == "number" and . > 0 and . <= 300;
def size_limit: type == "number" and floor == . and . >= 1 and . <= 2048;
reduce (split("\n")[] | sub("\r$"; "")
  | select(test("^\\s*(#.*)?$") | not)) as $line
  ({};
   ($line | capture("^\\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(?<value>\"(?:[^\"\\\\\\x00-\\x1f]|\\\\.)*\"|true|false|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\\s*(?:#.*)?$")
     // error("unsupported TOML syntax")) as $pair
   | checked(has($pair.key) | not)
   | .[$pair.key] = ($pair.value | fromjson))
| checked((.library_id | type == "number" or type == "string"))
| .library_id |= tostring
| checked(.library_id | test("^[0-9]+$"))
| checked(.library_type == "user" or .library_type == "group")
| checked(.api_key | text and length > 0)
| .use_webdav = (.use_webdav // false)
| checked(.use_webdav | type == "boolean")
| .webdav_allow_http = (.webdav_allow_http // false)
| checked(.webdav_allow_http | type == "boolean")
| .broker_timeout_s = (.broker_timeout_s // 30)
| .webdav_timeout_s = (.webdav_timeout_s // 60)
| .zotero_timeout_s = (.zotero_timeout_s // 60)
| checked(.broker_timeout_s | positive_timeout)
| checked(.webdav_timeout_s | positive_timeout)
| checked(.zotero_timeout_s | positive_timeout)
| .webdav_max_download_mb = (.webdav_max_download_mb // 100)
| .zotero_max_download_mb = (.zotero_max_download_mb // 100)
| checked(.webdav_max_download_mb | size_limit)
| checked(.zotero_max_download_mb | size_limit)
| .mb_in_path = (.mb_in_path // "/run/xovi-mb")
| .mb_out_path = (.mb_out_path // "/run/xovi-mb-out")
| .state_db_path = (.state_db_path // "./zotbridge-state.db")
| .state_json_path = (.state_json_path // (.state_db_path + ".json"))
| .default_target_folder = (.default_target_folder // "Zotero/unread")
| .reverse_sync_folder = (.reverse_sync_folder // "Zotero/Read")
| .sync_queue_tag = (.sync_queue_tag // "to_sync")
| .sync_synced_tag = (.sync_synced_tag // "synced")
| checked([.default_target_folder,.reverse_sync_folder] | all(
    text and (split("/") | all(gsub("^\\s+|\\s+$";"") | length>0))
    and (test("^(?:urn:uuid:)?\\{?[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\\}?$") | not)))
| checked([.sync_queue_tag,.sync_synced_tag] | all(text and length>0
    and ((contains("||") or startswith("\\-") or test("[\u0000-\u001f\u007f]")) | not)))
| checked(.sync_queue_tag != .sync_synced_tag)
| .xochitl_dir = (.xochitl_dir // env.XOCHITL_DIR // "/home/root/.local/share/remarkable/xochitl")
| checked([.mb_in_path, .mb_out_path, .state_db_path, .state_json_path, .xochitl_dir]
          | all(text and length > 0))
| if .use_webdav then
    checked(.library_type == "user")
    | checked([.webdav_url, .webdav_username, .webdav_password] | all(text and (gsub("^\\s+|\\s+$"; "") | length > 0)))
    | checked(.webdav_username | contains(":") | not)
    | checked(.webdav_url | test("^https?://[^/@?#\\s]+(?:/[^?#\\s]*)?$"))
    | checked((.webdav_url | startswith("https://")) or .webdav_allow_http)
    | .webdav_url |= (sub("/+$"; "") + "/")
  else . end
