# Computes a 1-based, comma-separated PDF page range covering only the
# annotated pages of a document, for trimPdf (via xovi-message-broker).
#
# Main input: a JSON array of annotated reMarkable page ids (from the
# getContentPages broker signal, one id per line).
# --slurpfile content: the document's <uuid>.content file, wrapped in an
# array by jq's --slurpfile.
#
# Supports both the modern cPages.pages format and the older flat
# pages/redirectionPageMap format, mirroring xovi-qmd-extensions'
# duplicateAnnotatedPages.qmd page-to-PDF-index mapping logic.
. as $ids
| $content[0] as $doc
| (
    if ($doc.cPages.pages | type) == "array" then
        [$doc.cPages.pages[] | select(.id as $pid | $ids | index($pid) != null)
         | (.redir.value // -1)]
    else
        ($doc.pages // []) as $flat
        | ($doc.redirectionPageMap // []) as $redir
        | [range(0; ($flat | length)) as $i
           | select($flat[$i] as $pid | $ids | index($pid) != null)
           | ($redir[$i] // $i)]
    end
  )
| map(select(. >= 0)) | unique | sort
| if length == 0 then empty else (map(. + 1) | join(",")) end
