def unzip_entries:
  (split("\n") | map(select(length>0))) as $lines
  | [$lines[] | capture("^ *(?<size>[0-9]+) +[0-9]{2,4}-[0-9]{2}-[0-9]{2,4} +[0-9]{2}:[0-9]{2} {3}(?<raw>.*)$")
     | .size |= tonumber] as $entries
  | [$lines[] | capture("^ *(?<size>[0-9]+) +(?<count>[0-9]+) files? *$")
     | .size |= tonumber | .count |= tonumber] as $totals
  | if ($totals|length)!=1 or ($entries|length)==0
       or ($entries|length)!=$totals[0].count
       or ([$entries[].size]|add)!=$totals[0].size
    then error("ambiguous ZIP listing") else $entries end;

def seven_zip_entries:
  [split("\n\n")[]
   | select(length>0)
   | (split("\n") | map(select(length>0))) as $lines
   | ([$lines[] | capture("^Path = (?<value>.*)$").value]) as $paths
   | ([$lines[] | capture("^Size = (?<value>[0-9]+)$").value]) as $sizes
   | ([$lines[] | capture("^Folder = (?<value>.*)$").value]) as $folders
   | ([$lines[] | capture("^Encrypted = (?<value>.*)$").value]) as $encrypted
   | if ($paths|length)!=1 or ($sizes|length)!=1 or ($folders|length)!=1
        or ($encrypted|length)!=1 or $folders[0]!="-" or $encrypted[0]!="-"
     then error("ambiguous 7-Zip listing")
     else {raw:$paths[0],size:($sizes[0]|tonumber)} end];

(if $format=="7zz" then seven_zip_entries
 elif $format=="unzip" then unzip_entries
 else error("unsupported ZIP listing format") end) as $entries
| if ($entries|length)==0 or ([$entries[].raw]|unique|length)!=($entries|length)
  then error("empty or duplicate ZIP listing") else . end
| [$entries[] | .raw as $raw
   | (if $raw|endswith("%ZB64") then
        ($raw[0:-5]) as $b64
        | if ($b64|test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")|not)
          then error("invalid encoded name") else ($b64|@base64d) end
        | if contains("\ufffd") then error("invalid UTF-8 name") else . end
      else $raw end) as $name
   | if ($raw|test("[\\\\\\[\\]*?\u0000-\u001f\u007f]") or startswith("-") or startswith("/"))
        or ($name|test("[\\\\:\u0000-\u001f\u007f]") or startswith("/")
            or (split("/")|index("..")!=null))
     then error("unsafe or unsupported member name") else . end
   | select($name|ascii_downcase|endswith(".pdf"))
   | . + {name:$name}] as $candidates
| ($candidates | map(select(.name==($attachment[0].data.filename // "")))) as $matches
| (if ($matches|length)==1 then $matches[0]
   elif ($candidates|length)==1 then $candidates[0]
   else error("no uniquely identifiable PDF") end)
| if .size<5 or .size>$limit then error("PDF exceeds size bounds") else . end
