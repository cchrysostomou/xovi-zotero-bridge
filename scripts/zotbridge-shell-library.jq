def ancestry($entries; $id; $seen; $names):
  if $id == "" then {path: ($names | reverse | join("/"))}
  elif $id == "trash" then {hidden:true}
  elif $seen[$id] then {warning:"cyclic parent hierarchy"}
  elif $entries[$id] == null then {warning:("missing parent " + $id)}
  elif $entries[$id].deleted then {hidden:true}
  else ancestry($entries; $entries[$id].parent; $seen + {($id):true};
                $names + [$entries[$id].title])
  end;
([.[] | select(.entry) | .entry] | INDEX(.rm_uuid)) as $entries
| [.[] | select(.warning) | .warning] as $warnings
| [$entries[] | . as $entry
   | ancestry($entries; .rm_uuid; {}; []) as $path
   | if $path.warning then {warning:(.rm_uuid + ": " + $path.warning)}
     elif $path.hidden then empty
     else {entry:($entry | del(.deleted) | . + $path)} end] as $resolved
| {ok:true,
   entries:([$resolved[] | select(.entry) | .entry]
            | sort_by(.type != "CollectionType", (.path | ascii_downcase))),
   warnings:($warnings + [$resolved[] | select(.warning) | .warning])}
