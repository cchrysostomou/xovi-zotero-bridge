import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.ApploadUtils
import net.asivery.CommandExecutor 1.0

Rectangle {
    id: app
    anchors.fill: parent
    color: "white"

    signal close
    function unloading() {}

    property var tags: []
    property var selectedTags: []
    property var collections: []
    property string selectedCollection: ""
    property var items: []
    property var pagination: ({skip: 0, limit: 8, total: 0, has_more: false, next_skip: null})
    property string status: "Loading Zotero settings…"
    property string pendingAction: ""
    property string commandError: ""
    property bool busy: false
    property bool tagsVisible: false
    property bool collectionsVisible: false
    property bool hideOnRemarkable: false
    property string tagAlphaFilter: "All"
    property string sortField: "dateModified"
    property string sortDirection: "desc"
    property int activeIndex: -1
    property string lastQuery: ""
    property int lastSkip: 0
    property string toast: ""
    property bool bootstrapped: false

    // Caches fetched list pages so paging back doesn't refetch. Keyed by
    // query+tags+collection+limit+skip; capped at the latest 1000 cached
    // items (evicting oldest pages first) and cleared whenever the search
    // itself changes (not just the page) or the app is (re)opened.
    property var pageCache: ({})
    property var pageCacheOrder: []
    property int pageCacheItemCount: 0
    property string currentSignature: ""
    property string pendingCacheKey: ""
    property int pageCacheLimit: 1000

    // Whole-result-set cache. A background walk pages through every item
    // matching the current query/tags/collection on a second command channel,
    // so it never sets `busy` and never blocks the UI. The walk is keyed on
    // the *result set* only (sort and page size are deliberately excluded),
    // so once it completes, changing the sort or the page re-slices this list
    // locally instead of re-querying Zotero.
    property string datasetKey: ""
    property var datasetItems: []
    property var datasetSeen: ({})
    property int datasetTotal: 0
    property bool datasetComplete: false
    property bool datasetFailed: false
    property int prefetchSkip: 0
    property bool prefetchBusy: false
    // Zotero's latency is erratic (measured 2.8s-32s for identical requests,
    // against a 60s backend timeout), so an occasional failed page is expected
    // rather than fatal; only a repeatedly failing offset abandons the walk.
    property int prefetchRetries: 0
    property int prefetchMaxRetries: 3
    // Set by the Refresh button so the next walk re-queries Zotero instead of
    // reusing the backend's 24h on-disk cache.
    property bool prefetchForceRefresh: false
    // The walk uses full 100-item pages rather than the UI's page size: a
    // 650-item library is ~7 requests instead of ~80, which matters because
    // each round trip to Zotero has been measured at 0.6-11s.
    property int prefetchPageSize: 100
    property string prefetchNote: ""

    // Per-item state for the tap-to-fetch/expand attachment list: keyed by
    // item_key -> {fetching, children (null until fetched), expanded}.
    // Survives page refreshes (it is not cleared by loadPage/clearPageCache).
    property var itemUiState: ({})
    property string pendingChildrenKey: ""

    // Multi-select download state. Selection is keyed by
    // "<item_key>::<attachment_key>" -> {itemKey, attachmentKey, title}.
    // The tag toggles apply to the whole batch, not per-attachment, since
    // per-attachment checkboxes conflicted with touch input on-device.
    property var selectedAttachments: ({})
    property int selectedCount: 0
    property bool batchIncludeZoteroTags: true
    property bool batchAddUnreadTag: true
    property var downloadQueue: []
    property int downloadQueueTotal: 0
    property int downloadQueueDone: 0

    // Rolling log of bridge command invocations/results, shown via a
    // show/hide toggle (mirrors the "Show tags"/"Hide tags" pattern) below
    // the file list, for on-device debugging without SSH access.
    property var logEntries: []
    property bool logVisible: false
    property int logLimit: 200

    function appendLog(line) {
        var timestamp = new Date().toTimeString().slice(0, 8);
        var next = logEntries.concat([timestamp + "  " + line]);
        if (next.length > logLimit) next = next.slice(next.length - logLimit);
        logEntries = next;
    }

    function stateFor(itemKey) {
        return itemUiState[itemKey] || {fetching: false, children: null, expanded: false};
    }

    function setItemState(itemKey, patch) {
        var next = Object.assign({}, stateFor(itemKey), patch);
        var updated = Object.assign({}, itemUiState);
        updated[itemKey] = next;
        itemUiState = updated;
    }

    function selectionKey(itemKey, attachmentKey) {
        return itemKey + "::" + attachmentKey;
    }

    function isSelected(itemKey, attachmentKey) {
        return !!selectedAttachments[selectionKey(itemKey, attachmentKey)];
    }

    function toggleAttachmentSelection(itemKey, attachmentKey, title) {
        var key = selectionKey(itemKey, attachmentKey);
        var updated = Object.assign({}, selectedAttachments);
        if (updated[key]) {
            delete updated[key];
        } else {
            updated[key] = {itemKey: itemKey, attachmentKey: attachmentKey, title: title};
        }
        selectedAttachments = updated;
        selectedCount = Object.keys(selectedAttachments).length;
    }

    function selectAllAttachmentsForItem(itemKey) {
        var state = stateFor(itemKey);
        if (!state.children || state.children.length === 0) return;
        var updated = Object.assign({}, selectedAttachments);
        for (var i = 0; i < state.children.length; i++) {
            var attachment = state.children[i];
            updated[selectionKey(itemKey, attachment.attachment_key)] =
                {itemKey: itemKey, attachmentKey: attachment.attachment_key, title: attachment.title};
        }
        selectedAttachments = updated;
        selectedCount = Object.keys(selectedAttachments).length;
    }

    function clearSelection() {
        selectedAttachments = {};
        selectedCount = 0;
    }

    function startBatchDownload() {
        if (selectedCount === 0 || busy) return;
        downloadQueue = Object.values(selectedAttachments);
        downloadQueueTotal = downloadQueue.length;
        downloadQueueDone = 0;
        runNextDownload();
    }

    function runNextDownload() {
        if (downloadQueue.length === 0) {
            downloadQueueTotal = 0;
            downloadQueueDone = 0;
            clearSelection();
            toast = "Download batch complete";
            status = toast;
            return;
        }
        var next = downloadQueue.shift();
        var args = ["import", "--item-key", next.itemKey, "--attachment-key", next.attachmentKey];
        if (batchIncludeZoteroTags) args.push("--include-zotero-tags");
        if (batchAddUnreadTag) args.push("--add-unread-tag");
        status = "Downloading " + (downloadQueueDone + 1) + "/" + downloadQueueTotal +
                  ": " + next.attachmentKey + "…";
        run(args, "import");
    }

    function querySignature() {
        var sortedTags = selectedTags.slice().sort();
        return JSON.stringify({q: searchInput.text, tags: sortedTags,
            collection: selectedCollection, limit: pagination.limit,
            sort: sortField, direction: sortDirection});
    }

    function clearPageCache() {
        pageCache = {};
        pageCacheOrder = [];
        pageCacheItemCount = 0;
    }

    // Identity of the result set itself. Sort and page size are excluded on
    // purpose: they only change how an already-fetched set is presented.
    function datasetSignature() {
        var sortedTags = selectedTags.slice().sort();
        return JSON.stringify({q: searchInput.text, tags: sortedTags,
            collection: selectedCollection});
    }

    function resetDataset(forceRefresh) {
        datasetKey = datasetSignature();
        datasetItems = [];
        datasetSeen = {};
        datasetTotal = 0;
        datasetComplete = false;
        datasetFailed = false;
        prefetchSkip = 0;
        prefetchRetries = 0;
        prefetchForceRefresh = (forceRefresh === true);
        prefetchNote = "";
    }

    function prefetchArguments(skip) {
        // Pinned to a fixed sort so that changing the UI sort mid-walk cannot
        // reshuffle the server-side paging underneath us and make the walk
        // skip or repeat items. The collected set is order-independent.
        var args = ["list", "--page-info", "--limit", String(prefetchPageSize),
                    "--skip", String(skip), "--query", searchInput.text,
                    "--sort", "dateAdded", "--direction", "desc"];
        // Only the first page of a user-requested refresh needs to bypass the
        // backend's 24h cache; once it is refetched the rest of the walk can
        // reuse whatever is still fresh.
        if (prefetchForceRefresh) args.push("--refresh");
        for (var i = 0; i < selectedTags.length; i++) {
            args.push("--tag");
            args.push(selectedTags[i]);
        }
        if (selectedCollection.length > 0) {
            args.push("--collection");
            args.push(selectedCollection);
        }
        return args;
    }

    function prefetchTick() {
        if (!bootstrapped || datasetComplete || datasetFailed) return;
        // Yield to anything the user asked for; the timer retries later.
        if (busy || prefetchBusy) return;
        if (datasetSignature() !== datasetKey) return;
        prefetchBusy = true;
        prefetchCommand.output = "";
        prefetchCommand.errorOutput = "";
        prefetchCommand.arguments = [
            "/home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh"
        ].concat(prefetchArguments(prefetchSkip));
        if (!prefetchCommand.startCommand(120000)) {
            prefetchBusy = false;
            prefetchFailedAttempt("could not start");
        }
    }

    function prefetchFailedAttempt(reason) {
        prefetchRetries += 1;
        appendLog("✕ [prefetch] skip=" + prefetchSkip + " " + reason +
                   " (attempt " + prefetchRetries + "/" + prefetchMaxRetries + ")");
        if (prefetchRetries >= prefetchMaxRetries) {
            datasetFailed = true;
            prefetchNote = "";
        }
    }

    function finishPrefetch() {
        prefetchBusy = false;
        var result;
        try {
            result = JSON.parse(prefetchCommand.output);
        } catch (error) {
            result = null;
        }
        // A background walk must never hijack the status line or surface an
        // error dialog: retry quietly, and on repeated failure just leave
        // paging on the normal server-backed path.
        if (!result || prefetchCommand.exitCode !== 0 || result.ok !== true) {
            prefetchFailedAttempt((result && result.error) || "exit " + prefetchCommand.exitCode);
            return;
        }
        if (datasetSignature() !== datasetKey) return;
        prefetchRetries = 0;
        prefetchForceRefresh = false;
        var fetched = result.items || [];
        var merged = datasetItems.slice();
        for (var i = 0; i < fetched.length; i++) {
            var key = fetched[i].item_key;
            if (!key || datasetSeen[key]) continue;
            datasetSeen[key] = true;
            merged.push(fetched[i]);
        }
        datasetItems = merged;
        var info = result.pagination || {};
        if (info.total !== undefined) datasetTotal = info.total;
        var next = info.next_skip;
        if (next === null || next === undefined || fetched.length === 0) {
            datasetComplete = true;
            prefetchNote = "";
            appendLog("✓ [prefetch] cached all " + datasetItems.length + " papers");
        } else {
            prefetchSkip = next;
            prefetchNote = "Caching " + datasetItems.length + "/" + datasetTotal + "…";
        }
    }

    // Mirrors Zotero's sort fields closely enough for re-slicing a cached set.
    // Zotero's own collation (which ignores leading articles) is not
    // reproduced, so a locally sorted page can differ slightly from a
    // server-sorted one for titles like "The ...".
    function compareItems(a, b, field) {
        var left, right;
        if (field === "title") {
            left = (a.title || "").toLowerCase();
            right = (b.title || "").toLowerCase();
        } else if (field === "creator") {
            left = (a.creator || "").toLowerCase();
            right = (b.creator || "").toLowerCase();
        } else if (field === "dateAdded") {
            left = a.date_added || "";
            right = b.date_added || "";
        } else {
            left = a.date_modified || "";
            right = b.date_modified || "";
        }
        if (left < right) return -1;
        if (left > right) return 1;
        // Deterministic tiebreak, otherwise equal keys could reshuffle between
        // pages and an item could appear twice or not at all.
        if (a.item_key < b.item_key) return -1;
        if (a.item_key > b.item_key) return 1;
        return 0;
    }

    function sortedDataset() {
        var field = sortField;
        var sign = (sortDirection === "desc") ? -1 : 1;
        return datasetItems.slice().sort(function(a, b) {
            return sign * compareItems(a, b, field);
        });
    }

    function serveFromDataset(skip) {
        var sorted = sortedDataset();
        var limit = pagination.limit;
        var start = Math.max(0, Math.min(skip, Math.max(0, sorted.length - 1)));
        if (sorted.length === 0) start = 0;
        var hasMore = (start + limit) < sorted.length;
        items = sorted.slice(start, start + limit);
        pagination = {skip: start, limit: limit, total: sorted.length,
                      has_more: hasMore, next_skip: hasMore ? start + limit : null};
        lastSkip = start;
        status = "Showing " + items.length + " of " + pagination.total + " papers (cached)";
    }

    function cachePage(key, pageItems, pageInfo) {
        if (!key) return;
        if (pageCache[key]) {
            pageCacheItemCount -= pageCache[key].items.length;
            var existingIndex = pageCacheOrder.indexOf(key);
            if (existingIndex >= 0) pageCacheOrder.splice(existingIndex, 1);
        }
        pageCache[key] = {items: pageItems, pagination: pageInfo};
        pageCacheOrder.push(key);
        pageCacheItemCount += pageItems.length;
        while (pageCacheItemCount > pageCacheLimit && pageCacheOrder.length > 0) {
            var oldestKey = pageCacheOrder.shift();
            if (pageCache[oldestKey]) pageCacheItemCount -= pageCache[oldestKey].items.length;
            delete pageCache[oldestKey];
        }
    }

    function run(arguments, action) {
        if (busy) return;
        busy = true;
        pendingAction = action;
        bridgeCommand.output = "";
        bridgeCommand.errorOutput = "";
        bridgeCommand.arguments = [
            "/home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh"
        ].concat(arguments);
        appendLog("→ " + arguments.join(" "));
        if (!bridgeCommand.startCommand(action === "import" ? 60000 : 30000)) {
            busy = false;
            status = "Could not start bridge command";
            appendLog("✕ could not start bridge command");
        }
    }

    function loadTags(refresh) {
        status = refresh ? "Refreshing Zotero tags…" : "Loading Zotero tags…";
        run(refresh ? ["tags", "--refresh", "--json"] : ["tags", "--json"], "tags");
    }

    function loadCollections(refresh) {
        status = refresh ? "Refreshing Zotero collections…" : "Loading Zotero collections…";
        run(refresh ? ["collections", "--refresh", "--json"] : ["collections", "--json"], "collections");
    }

    function loadSettings() {
        status = "Loading Zotero settings…";
        run(["settings", "--json"], "settings");
    }

    function listArguments(skip, forceRefresh) {
        var args = ["list", "--page-info", "--limit", String(pagination.limit),
                    "--skip", String(skip), "--query", searchInput.text,
                    "--sort", sortField, "--direction", sortDirection];
        if (forceRefresh) args.push("--refresh");
        for (var i = 0; i < selectedTags.length; i++) {
            args.push("--tag");
            args.push(selectedTags[i]);
        }
        if (selectedCollection.length > 0) {
            args.push("--collection");
            args.push(selectedCollection);
        }
        return args;
    }

    function loadPage(skip, forceRefresh) {
        lastQuery = searchInput.text;
        lastSkip = skip;
        if (forceRefresh || datasetSignature() !== datasetKey) resetDataset(forceRefresh);
        // Once the whole result set is cached, paging and re-sorting are pure
        // local work: no Zotero request at all.
        if (datasetComplete) {
            serveFromDataset(skip);
            return;
        }
        var signature = querySignature();
        if (signature !== currentSignature) {
            clearPageCache();
            currentSignature = signature;
        }
        var key = signature + "::skip=" + skip;
        if (!forceRefresh && pageCache[key]) {
            var cached = pageCache[key];
            items = cached.items;
            pagination = cached.pagination;
            status = "Showing " + items.length + " of " + pagination.total + " papers (cached)";
            return;
        }
        pendingCacheKey = key;
        status = forceRefresh ? "Refreshing from Zotero…" : "Loading Zotero papers…";
        items = [];
        run(listArguments(skip, forceRefresh), "list");
    }

    function refreshCurrentPage() {
        loadPage(lastSkip, true);
    }

    function pageCount() {
        return Math.max(1, Math.ceil(app.pagination.total / app.pagination.limit));
    }

    function currentPage() {
        return Math.min(pageCount(), Math.floor(app.pagination.skip / app.pagination.limit) + 1);
    }

    function pageJumpers() {
        var first = Math.max(1, currentPage() - 10);
        var last = Math.min(pageCount(), currentPage() + 10);
        var pages = [];
        for (var page = first; page <= last; page++) pages.push(page);
        return pages;
    }

    function loadPageNumber(page) {
        loadPage((page - 1) * app.pagination.limit);
    }

    function toggleTag(tag) {
        var next = selectedTags.slice(0);
        var index = next.indexOf(tag);
        if (index >= 0) next.splice(index, 1);
        else next.push(tag);
        selectedTags = next;
        loadPage(0);
    }

    function clearTags() {
        if (selectedTags.length === 0) return;
        selectedTags = [];
        loadPage(0);
    }

    function filteredTags() {
        var query = tagSearch.text.toLowerCase();
        return tags.filter(function(tag) {
            if (query.length !== 0 && tag.toLowerCase().indexOf(query) === -1) return false;
            if (tagAlphaFilter === "All") return true;
            if (tag.length === 0) return false;
            if (tagAlphaFilter === "#") return !(/[A-Za-z]/.test(tag.charAt(0)));
            return tag.charAt(0).toUpperCase() === tagAlphaFilter;
        });
    }

    function toggleCollection(collectionKey) {
        selectedCollection = (selectedCollection === collectionKey) ? "" : collectionKey;
        loadPage(0);
    }

    function clearCollection() {
        if (selectedCollection.length === 0) return;
        selectedCollection = "";
        loadPage(0);
    }

    function filteredCollections() {
        var query = collectionSearch.text.toLowerCase();
        if (query.length === 0) return collectionTree;
        // Searching flattens the hierarchy: match on the collection's own
        // name, but show the full path so same-named children stay distinct.
        var rows = collectionTree;
        var out = [];
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].name.toLowerCase().indexOf(query) !== -1)
                out.push({key: rows[i].key, name: rows[i].name,
                          path: rows[i].path, depth: 0, flat: true});
        }
        out.sort(function(a, b) {
            var an = a.name.toLowerCase(), bn = b.name.toLowerCase();
            return an < bn ? -1 : (an > bn ? 1 : 0);
        });
        return out;
    }

    // Flattens `collections` into display order: each child directly follows
    // its parent, carrying a depth for indentation and a "Parent / Child"
    // path for the flattened search view. Held as a binding rather than a
    // function so it is recomputed only when `collections` changes, and so
    // the unfiltered picker keeps handing the Repeater the same array
    // instead of rebuilding every delegate on each re-evaluation.
    property var collectionTree: {
        var byParent = {};
        var known = {};
        var i;
        for (i = 0; i < collections.length; i++) known[collections[i].key] = true;
        for (i = 0; i < collections.length; i++) {
            var c = collections[i];
            // A parent that isn't in the library (trashed, or outside this
            // library's scope) would otherwise strand its children and hide
            // them entirely, so treat those as top level.
            var p = (c.parent && known[c.parent]) ? c.parent : "";
            if (!byParent[p]) byParent[p] = [];
            byParent[p].push(c);
        }
        for (var k in byParent) {
            byParent[k].sort(function(a, b) {
                var an = (a.name || "").toLowerCase(), bn = (b.name || "").toLowerCase();
                return an < bn ? -1 : (an > bn ? 1 : 0);
            });
        }
        var out = [];
        var seen = {};
        var walk = function(parentKey, depth, prefix) {
            var kids = byParent[parentKey] || [];
            for (var j = 0; j < kids.length; j++) {
                var kid = kids[j];
                // Defensive: a cycle in cached data would otherwise recurse
                // until the UI hangs.
                if (seen[kid.key]) continue;
                seen[kid.key] = true;
                var path = prefix.length > 0 ? (prefix + " / " + kid.name) : kid.name;
                out.push({key: kid.key, name: kid.name, path: path,
                          depth: depth, flat: false});
                walk(kid.key, depth + 1, path);
            }
        };
        walk("", 0, "");
        return out;
    }

    function setSortField(field) {
        if (sortField === field) {
            sortDirection = (sortDirection === "asc") ? "desc" : "asc";
        } else {
            sortField = field;
            // Names and creators read naturally A→Z; dates are most useful newest first.
            sortDirection = (field === "title" || field === "creator") ? "asc" : "desc";
        }
        activeIndex = -1;
        loadPage(0);
    }

    function itemSubtitle(item) {
        var parts = [];
        if (item.creator) parts.push(item.creator);
        if (item.year) parts.push(item.year);
        var count = (typeof item.num_children === "number") ? item.num_children : 0;
        parts.push("Estimated file items: " + count);
        if (item.mapping) parts.push("on reMarkable");
        if (item.attempt) parts.push("attempt pending");
        return parts.join("  ·  ");
    }

    function itemRemarkablePath(item) {
        return (item.mapping && item.mapping.rm_path) ? item.mapping.rm_path : "";
    }

    function isOnRemarkable(item) {
        return !!(item && item.mapping);
    }

    function visibleItems() {
        if (!hideOnRemarkable) return items;
        var out = [];
        for (var i = 0; i < items.length; i++) {
            if (!isOnRemarkable(items[i])) out.push(items[i]);
        }
        return out;
    }

    function hiddenItemCount() {
        if (!hideOnRemarkable) return 0;
        return items.length - visibleItems().length;
    }

    function fetchChildren(item, index) {
        if (!item || !item.item_key || busy) return;
        activeIndex = index;
        pendingChildrenKey = item.item_key;
        setItemState(item.item_key, {fetching: true});
        status = "Fetching items for " + item.item_key + "…";
        run(["children", "--item-key", item.item_key, "--json"], "children");
    }

    function toggleExpanded(item) {
        if (!item || !item.item_key) return;
        var state = stateFor(item.item_key);
        if (state.children === null) return;
        setItemState(item.item_key, {expanded: !state.expanded});
    }

    function tapItem(item, index) {
        if (!item || !item.item_key || busy) return;
        var state = stateFor(item.item_key);
        if (state.children === null) {
            fetchChildren(item, index);
        } else {
            toggleExpanded(item);
        }
    }

    function finishCommand() {
        busy = false;
        var result;
        try {
            result = JSON.parse(bridgeCommand.output);
        } catch (error) {
            status = bridgeCommand.exitCode !== 0 ?
                "Bridge command failed (exit " + bridgeCommand.exitCode + ")" :
                "Bridge returned an invalid response";
            commandError = bridgeCommand.errorOutput;
            appendLog("✕ [" + pendingAction + "] exit " + bridgeCommand.exitCode +
                       (commandError ? ": " + commandError : " (invalid JSON output)"));
            clearPendingChildrenFetch();
            abortBatchDownload();
            return;
        }
        commandError = "";
        if (Array.isArray(result)) {
            appendLog("✓ [" + pendingAction + "] " + result.length + " item(s)");
            if (pendingAction === "collections") {
                collections = result;
                status = "Loaded " + result.length + " collections";
                if (!bootstrapped) {
                    bootstrapped = true;
                    loadPage(0);
                }
            } else {
                tags = result;
                status = "Loaded " + result.length + " tags";
                if (!bootstrapped) {
                    loadCollections(false);
                } else {
                    loadPage(0);
                }
            }
            return;
        }
        if (pendingAction === "settings") {
            if (bridgeCommand.exitCode !== 0) {
                status = "Bridge error loading settings";
                appendLog("✕ [settings] exit " + bridgeCommand.exitCode);
                return;
            }
            appendLog("✓ [settings] loaded");
            var limit = result.list_page_limit;
            pagination = Object.assign({}, pagination, {limit: (limit && limit > 0) ? limit : pagination.limit});
            loadTags(false);
            return;
        }
        if (bridgeCommand.exitCode !== 0 || result.ok !== true) {
            status = "Bridge error: " + (result.error || "command exited " + bridgeCommand.exitCode);
            appendLog("✕ [" + pendingAction + "] " + (result.error || "exit " + bridgeCommand.exitCode));
            clearPendingChildrenFetch();
            abortBatchDownload();
            return;
        }
        if (pendingAction === "list") {
            items = result.items || [];
            pagination = result.pagination || pagination;
            cachePage(pendingCacheKey, items, pagination);
            pendingCacheKey = "";
            status = "Showing " + items.length + " of " + pagination.total + " papers";
            appendLog("✓ [list] " + items.length + " of " + pagination.total + " papers");
        } else if (pendingAction === "children") {
            var childItems = result.attachments || [];
            setItemState(pendingChildrenKey, {fetching: false, children: childItems, expanded: true});
            status = "Found " + childItems.length + " downloadable item" + (childItems.length === 1 ? "" : "s");
            appendLog("✓ [children] " + pendingChildrenKey + " → " + childItems.length + " attachment(s)");
            pendingChildrenKey = "";
        } else if (pendingAction === "import") {
            appendLog("✓ [import] " + (result.attachment_key || result.item_key || "") +
                       (result.remarkable_tags_updated ? " (tags updated)" : "") +
                       (result.remarkable_tags_error ? " (tag error: " + result.remarkable_tags_error + ")" : ""));
            if (result.item_key) markItemImported(result.item_key, result.rm_path);
            if (downloadQueueTotal > 0) {
                downloadQueueDone += 1;
                runNextDownload();
            } else {
                toast = "Downloaded " + (result.attachment_key || result.item_key || "paper") + " to reMarkable";
                status = toast;
                activeIndex = -1;
            }
        } else {
            status = "Command complete";
        }
    }

    function markItemImported(itemKey, rmPath) {
        var patch = function(item) {
            if (item.item_key !== itemKey) return item;
            return Object.assign({}, item, {mapping: {rm_path: rmPath}, attempt: false});
        };
        items = items.map(patch);
        // The cached set backs every later page render, so it has to learn
        // about the import too or the badge would vanish on the next page turn.
        if (datasetItems.length > 0) datasetItems = datasetItems.map(patch);
    }

    function clearPendingChildrenFetch() {
        if (pendingAction === "children" && pendingChildrenKey) {
            setItemState(pendingChildrenKey, {fetching: false});
            pendingChildrenKey = "";
        }
    }

    function abortBatchDownload() {
        if (downloadQueueTotal === 0) return;
        toast = "Download batch stopped after " + downloadQueueDone + "/" + downloadQueueTotal +
                 " (" + status + ")";
        downloadQueue = [];
        downloadQueueTotal = 0;
        downloadQueueDone = 0;
        clearSelection();
        refreshCurrentPage();
    }

    AsyncCommandExecutor {
        id: bridgeCommand
        command: "sh"
        property string output: ""
        property string errorOutput: ""
        onStdOutAvailable: function(chunk) { output += chunk; }
        onStdErrAvailable: function(chunk) { errorOutput += chunk; }
        onRunningChanged: {
            if (!running && app.busy) app.finishCommand();
        }
    }

    // Separate channel so the background walk never touches `busy` and can
    // therefore never disable the UI or swallow a user action.
    AsyncCommandExecutor {
        id: prefetchCommand
        command: "sh"
        property string output: ""
        property string errorOutput: ""
        onStdOutAvailable: function(chunk) { output += chunk; }
        onStdErrAvailable: function(chunk) { errorOutput += chunk; }
        onRunningChanged: {
            if (!running && app.prefetchBusy) app.finishPrefetch();
        }
    }

    Timer {
        interval: 500
        repeat: true
        running: app.bootstrapped && !app.datasetComplete && !app.datasetFailed
        onTriggered: app.prefetchTick()
    }

    Component.onCompleted: loadSettings()

    Column {
        anchors.fill: parent
        anchors.margins: 36
        spacing: 16

        Row {
            width: parent.width
            spacing: 18
            Text {
                text: "Zotero Library"
                font.pixelSize: 46
                font.bold: true
                width: parent.width - 250
            }
            Rectangle {
                width: 220
                height: 64
                color: app.busy ? "#aaaaaa" : "black"
                Text { anchors.centerIn: parent; text: "Refresh"; color: "white"; font.pixelSize: 24 }
                MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.refreshCurrentPage() }
            }
        }

        Text {
            width: parent.width
            text: app.status + (app.prefetchNote ? "   " + app.prefetchNote : "")
            font.pixelSize: 22
            wrapMode: Text.WordWrap
        }

        Row {
            width: parent.width
            spacing: 14
            Rectangle {
                width: parent.width - 250
                height: 64
                color: "white"
                border.width: 2
                border.color: "black"
                TextInput {
                    id: searchInput
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    font.pixelSize: 24
                    selectByMouse: true
                    verticalAlignment: TextInput.AlignVCenter
                    Keys.onReturnPressed: { app.loadPage(0); searchInput.focus = false; Qt.inputMethod.hide(); }
                    Keys.onEnterPressed: { app.loadPage(0); searchInput.focus = false; Qt.inputMethod.hide(); }
                }
            }
            Rectangle {
                width: 210
                height: 64
                color: app.busy ? "#aaaaaa" : "black"
                Text { anchors.centerIn: parent; text: "Search"; color: "white"; font.pixelSize: 24 }
                MouseArea {
                    anchors.fill: parent
                    enabled: !app.busy
                    onClicked: { app.loadPage(0); searchInput.focus = false; Qt.inputMethod.hide(); }
                }
            }
        }

        Row {
            width: parent.width
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Sort"
                font.pixelSize: 20
            }
            Repeater {
                model: [{label: "Recent", field: "dateModified"},
                        {label: "Name", field: "title"},
                        {label: "Date added", field: "dateAdded"},
                        {label: "Creator", field: "creator"}]
                delegate: Rectangle {
                    width: 160
                    height: 52
                    color: app.sortField === modelData.field ? "black" : "white"
                    border.width: 2
                    border.color: "black"
                    Text {
                        anchors.centerIn: parent
                        text: modelData.label + (app.sortField === modelData.field
                              ? (app.sortDirection === "asc" ? "  ▲" : "  ▼") : "")
                        color: app.sortField === modelData.field ? "white" : "black"
                        font.pixelSize: 19
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: !app.busy
                        onClicked: app.setSortField(modelData.field)
                    }
                }
            }
            Item {
                width: 250
                height: 52
                Row {
                    id: notOnRmFilter
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Rectangle {
                        width: 30
                        height: 30
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 2
                        border.color: "black"
                        color: app.hideOnRemarkable ? "black" : "white"
                        Text {
                            anchors.centerIn: parent
                            text: app.hideOnRemarkable ? "✓" : ""
                            color: "white"
                            font.pixelSize: 20
                            font.bold: true
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Not on reMarkable"
                        font.pixelSize: 18
                    }
                }
                MouseArea {
                    anchors.fill: notOnRmFilter
                    onClicked: {
                        app.hideOnRemarkable = !app.hideOnRemarkable;
                        app.activeIndex = -1;
                    }
                }
            }
        }

        Row {
            width: parent.width
            spacing: 14
            Rectangle {
                width: 230
                height: 64
                color: "black"
                Text {
                    anchors.centerIn: parent
                    text: app.tagsVisible ? "Hide tags" : "Tags"
                    color: "white"
                    font.pixelSize: 24
                }
                MouseArea { anchors.fill: parent; onClicked: app.tagsVisible = !app.tagsVisible }
            }
            Rectangle {
                width: 280
                height: 64
                color: "black"
                Text {
                    anchors.centerIn: parent
                    text: app.collectionsVisible ? "Hide collections" : "Collections"
                    color: "white"
                    font.pixelSize: 24
                }
                MouseArea { anchors.fill: parent; onClicked: app.collectionsVisible = !app.collectionsVisible }
            }
        }

        Text {
            width: parent.width
            text: app.selectedTags.length === 0 ? "No tag filter selected" :
                  "Tags: " + app.selectedTags.join(", ")
            font.pixelSize: 20
            wrapMode: Text.WordWrap
        }

        Text {
            width: parent.width
            text: app.selectedCollection.length === 0 ? "No collection filter selected" :
                  "Collection: " + (function() {
                      for (var i = 0; i < app.collections.length; i++) {
                          if (app.collections[i].key === app.selectedCollection) return app.collections[i].name;
                      }
                      return app.selectedCollection;
                  })()
            font.pixelSize: 20
            wrapMode: Text.WordWrap
        }

        Rectangle {
            visible: app.tagsVisible
            width: parent.width
            height: visible ? 360 : 0
            color: "white"
            border.width: 2
            border.color: "black"
            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10
                Row {
                    width: parent.width
                    spacing: 12
                    Rectangle {
                        width: parent.width - 250
                        height: 52
                        color: "white"
                        border.width: 1
                        border.color: "black"
                        TextInput {
                            id: tagSearch
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            font.pixelSize: 21
                            selectByMouse: true
                            verticalAlignment: TextInput.AlignVCenter
                            Keys.onReturnPressed: { tagSearch.focus = false; Qt.inputMethod.hide(); }
                            Keys.onEnterPressed: { tagSearch.focus = false; Qt.inputMethod.hide(); }
                        }
                    }
                    Rectangle {
                        width: 110
                        height: 52
                        color: "black"
                        Text { anchors.centerIn: parent; text: "Clear"; color: "white"; font.pixelSize: 20 }
                        MouseArea { anchors.fill: parent; onClicked: app.clearTags() }
                    }
                    Rectangle {
                        width: 110
                        height: 52
                        color: app.busy ? "#aaaaaa" : "black"
                        Text { anchors.centerIn: parent; text: "Reload"; color: "white"; font.pixelSize: 20 }
                        MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.loadTags(true) }
                    }
                }
                Flickable {
                    width: parent.width
                    height: 60
                    clip: true
                    contentWidth: tagAlphaFilters.width
                    contentHeight: height
                    Row {
                        id: tagAlphaFilters
                        spacing: 8
                        Repeater {
                            model: ["All", "#", "A", "B", "C", "D", "E", "F", "G",
                                    "H", "I", "J", "K", "L", "M", "N", "O", "P",
                                    "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]
                            delegate: Rectangle {
                                width: modelData === "All" ? 66 : 44
                                height: 52
                                color: app.tagAlphaFilter === modelData ? "black" : "white"
                                border.width: 2
                                border.color: "black"
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: app.tagAlphaFilter === modelData ? "white" : "black"
                                    font.pixelSize: 20
                                }
                                MouseArea { anchors.fill: parent; onClicked: app.tagAlphaFilter = modelData }
                            }
                        }
                    }
                }
                Flickable {
                    width: parent.width
                    height: parent.height - 130
                    clip: true
                    contentWidth: width
                    contentHeight: tagList.height
                    interactive: contentHeight > height
                    Column {
                        id: tagList
                        width: parent.width
                        Repeater {
                            model: app.filteredTags()
                            delegate: Rectangle {
                                width: tagList.width
                                height: 50
                                color: app.selectedTags.indexOf(modelData) >= 0 ? "black" : "white"
                                border.width: 1
                                border.color: "black"
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: 12
                                    width: parent.width - 24
                                    text: modelData
                                    color: app.selectedTags.indexOf(modelData) >= 0 ? "white" : "black"
                                    font.pixelSize: 21
                                    elide: Text.ElideRight
                                }
                                MouseArea { anchors.fill: parent; onClicked: app.toggleTag(modelData) }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            visible: app.collectionsVisible
            width: parent.width
            height: visible ? 300 : 0
            color: "white"
            border.width: 2
            border.color: "black"
            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10
                Row {
                    width: parent.width
                    spacing: 12
                    Rectangle {
                        width: parent.width - 250
                        height: 52
                        color: "white"
                        border.width: 1
                        border.color: "black"
                        TextInput {
                            id: collectionSearch
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            font.pixelSize: 21
                            selectByMouse: true
                            verticalAlignment: TextInput.AlignVCenter
                            Keys.onReturnPressed: { collectionSearch.focus = false; Qt.inputMethod.hide(); }
                            Keys.onEnterPressed: { collectionSearch.focus = false; Qt.inputMethod.hide(); }
                        }
                    }
                    Rectangle {
                        width: 110
                        height: 52
                        color: "black"
                        Text { anchors.centerIn: parent; text: "Clear"; color: "white"; font.pixelSize: 20 }
                        MouseArea { anchors.fill: parent; onClicked: app.clearCollection() }
                    }
                    Rectangle {
                        width: 110
                        height: 52
                        color: app.busy ? "#aaaaaa" : "black"
                        Text { anchors.centerIn: parent; text: "Reload"; color: "white"; font.pixelSize: 20 }
                        MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.loadCollections(true) }
                    }
                }
                Flickable {
                    width: parent.width
                    height: parent.height - 70
                    clip: true
                    contentWidth: width
                    contentHeight: collectionList.height
                    interactive: contentHeight > height
                    Column {
                        id: collectionList
                        width: parent.width
                        Repeater {
                            model: app.filteredCollections()
                            delegate: Rectangle {
                                width: collectionList.width
                                height: 50
                                color: app.selectedCollection === modelData.key ? "black" : "white"
                                border.width: 1
                                border.color: "black"
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: 12 + modelData.depth * 26
                                    width: parent.width - 24 - modelData.depth * 26
                                    text: modelData.flat ? modelData.path :
                                          ((modelData.depth > 0 ? "└ " : "") + modelData.name)
                                    color: app.selectedCollection === modelData.key ? "white" : "black"
                                    font.pixelSize: 21
                                    elide: Text.ElideRight
                                }
                                MouseArea { anchors.fill: parent; onClicked: app.toggleCollection(modelData.key) }
                            }
                        }
                    }
                }
            }
        }

        // The space is reserved whether or not anything is selected, so the
        // bar appearing never shifts the list below it.
        Item {
            width: parent.width
            height: 64
            Rectangle {
                visible: app.selectedCount > 0
                anchors.fill: parent
                color: "white"
                border.width: 1
                border.color: "black"
                Row {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 16
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: app.selectedCount + " selected"
                        color: "black"
                        font.pixelSize: 20
                    }
                    Row {
                        spacing: 4
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            width: 26
                            height: 26
                            border.width: 2
                            border.color: "black"
                            color: app.batchIncludeZoteroTags ? "black" : "white"
                            Text {
                                anchors.centerIn: parent
                                text: app.batchIncludeZoteroTags ? "✓" : ""
                                color: "white"
                                font.pixelSize: 18
                                font.bold: true
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: app.batchIncludeZoteroTags = !app.batchIncludeZoteroTags
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Zotero tags"
                            color: "black"
                            font.pixelSize: 16
                        }
                    }
                    Row {
                        spacing: 4
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            width: 26
                            height: 26
                            border.width: 2
                            border.color: "black"
                            color: app.batchAddUnreadTag ? "black" : "white"
                            Text {
                                anchors.centerIn: parent
                                text: app.batchAddUnreadTag ? "✓" : ""
                                color: "white"
                                font.pixelSize: 18
                                font.bold: true
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: app.batchAddUnreadTag = !app.batchAddUnreadTag
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Unread"
                            color: "black"
                            font.pixelSize: 16
                        }
                    }
                    Rectangle {
                        width: 130
                        height: 44
                        anchors.verticalCenter: parent.verticalCenter
                        color: "black"
                        Text {
                            anchors.centerIn: parent
                            text: app.downloadQueueTotal > 0 ?
                                  "Downloading " + app.downloadQueueDone + "/" + app.downloadQueueTotal :
                                  "Download"
                            color: "white"
                            font.pixelSize: 16
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !app.busy
                            onClicked: app.startBatchDownload()
                        }
                    }
                    Rectangle {
                        width: 90
                        height: 44
                        anchors.verticalCenter: parent.verticalCenter
                        color: "black"
                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            color: "white"
                            font.pixelSize: 16
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: app.downloadQueueTotal === 0
                            onClicked: app.clearSelection()
                        }
                    }
                }
            }
        }

        Item {
            width: parent.width
            height: 60
            Text {
                id: pageCountLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                text: "Page " + app.currentPage() + "/" + app.pageCount() +
                      " (" + app.pagination.total + " total items)" +
                      (app.hiddenItemCount() > 0 ? "  ·  " + app.hiddenItemCount() + " hidden" : "")
                font.pixelSize: 22
                elide: Text.ElideRight
            }
        }

        Flickable {
            width: parent.width
            height: 60
            clip: true
            contentWidth: Math.max(width, pageJumpRow.width)
            contentHeight: height
            interactive: contentWidth > width
            Row {
                id: pageJumpRow
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                Repeater {
                    model: [
                        {label: "<<", page: 1, enabled: app.currentPage() > 1},
                        {label: "<", page: Math.max(1, app.currentPage() - 1), enabled: app.currentPage() > 1}
                    ].concat(app.pageJumpers()).concat([
                        {label: ">", page: Math.min(app.pageCount(), app.currentPage() + 1),
                         enabled: app.currentPage() < app.pageCount()},
                        {label: ">>", page: app.pageCount(), enabled: app.currentPage() < app.pageCount()}
                    ])
                    delegate: Rectangle {
                        width: modelData.label !== undefined ? 58 : 52
                        height: 52
                        color: modelData.label === undefined && app.currentPage() === modelData ?
                               "black" : "white"
                        border.width: 2
                        border.color: "black"
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label !== undefined ? modelData.label : modelData
                            color: modelData.label === undefined && app.currentPage() === modelData ?
                                   "white" : "black"
                            font.pixelSize: 20
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !app.busy &&
                                     (modelData.label === undefined ?
                                      app.currentPage() !== modelData : modelData.enabled)
                            onClicked: app.loadPageNumber(modelData.page !== undefined ?
                                                         modelData.page : modelData)
                        }
                    }
                }
            }
        }

        Rectangle {
            id: paperListPanel
            width: parent.width
            height: parent.height - y - 20 - 66 - (app.logVisible ? 216 : 0)
            color: "white"
            border.width: 2
            border.color: "black"
            Flickable {
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentWidth: width
                contentHeight: paperList.height
                interactive: contentHeight > height
                Column {
                    id: paperList
                    width: parent.width
                    Text {
                        visible: app.visibleItems().length === 0
                        width: parent.width
                        height: visible ? 80 : 0
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.pixelSize: 20
                        text: app.hiddenItemCount() > 0 ?
                              "All " + app.hiddenItemCount() + " items on this page are already on reMarkable." :
                              "No papers to show."
                    }
                    Repeater {
                        model: app.visibleItems()
                        delegate: Rectangle {
                            id: itemRow
                            property var paperItem: modelData
                            property int itemIndex: index
                            property var uiState: app.stateFor(modelData.item_key)
                            property string remarkablePath: app.itemRemarkablePath(modelData)
                            width: paperList.width
                            height: 128 + (remarkablePath ? 28 : 0) +
                                    (uiState.children !== null && uiState.expanded ?
                                     (24 + Math.max(uiState.children.length, 1) * 56) : 0)
                            color: "white"
                            border.width: index === app.activeIndex ? 3 : 1
                            border.color: "#555555"
                            Column {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8
                                Item {
                                    id: itemSummary
                                    width: parent.width
                                    height: 104 + (itemRow.remarkablePath ? 28 : 0)
                                    Column {
                                        anchors.fill: parent
                                        spacing: 8
                                        Row {
                                            width: parent.width
                                            spacing: 8
                                            Text {
                                                width: 24
                                                text: uiState.children !== null ? (uiState.expanded ? "▼" : "▶") : ""
                                                font.pixelSize: 20
                                                color: "#555555"
                                            }
                                            Text {
                                                width: parent.width - 32
                                                text: modelData.title || modelData.item_key
                                                font.pixelSize: 24
                                                font.bold: true
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Text {
                                            width: parent.width
                                            text: app.itemSubtitle(modelData)
                                            font.pixelSize: 18
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            visible: !!itemRow.remarkablePath
                                            width: parent.width
                                            text: "On reMarkable: " + itemRow.remarkablePath
                                            font.pixelSize: 20
                                            font.bold: true
                                            color: "#0000ee"
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            width: parent.width
                                            text: uiState.fetching ? "Fetching items…" :
                                                  "Tap to fetch items  ·  Long-press to select all  ·  " +
                                                  modelData.item_key
                                            font.pixelSize: 16
                                            color: modelData.has_pdf ? "black" : "#777777"
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: app.tapItem(itemRow.paperItem, itemRow.itemIndex)
                                        onPressAndHold: app.selectAllAttachmentsForItem(itemRow.paperItem.item_key)
                                    }
                                }
                                Column {
                                    width: parent.width
                                    spacing: 6
                                    visible: uiState.children !== null && uiState.expanded
                                    Text {
                                        visible: uiState.children && uiState.children.length === 0
                                        width: parent.width
                                        text: "No downloadable PDF attachments found"
                                        font.pixelSize: 16
                                        color: "#777777"
                                    }
                                    Repeater {
                                        model: uiState.children || []
                                        delegate: Rectangle {
                                            property bool selected: app.isSelected(
                                                itemRow.paperItem.item_key, modelData.attachment_key)
                                            width: itemRow.width - 24
                                            height: 48
                                            color: selected ? "black" : "#eeeeee"
                                            border.width: 1
                                            border.color: "#aaaaaa"
                                            Row {
                                                anchors.fill: parent
                                                anchors.margins: 6
                                                spacing: 10
                                                Text {
                                                    width: parent.width - 40
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.title || modelData.attachment_key
                                                    font.pixelSize: 16
                                                    color: selected ? "white" : "black"
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    width: 30
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: selected ? "✓" : ""
                                                    color: "white"
                                                    font.pixelSize: 20
                                                    font.bold: true
                                                }
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: app.toggleAttachmentSelection(
                                                    itemRow.paperItem.item_key, modelData.attachment_key,
                                                    modelData.title)
                                                onPressAndHold: app.toggleAttachmentSelection(
                                                    itemRow.paperItem.item_key, modelData.attachment_key,
                                                    modelData.title)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Text {
                visible: app.busy && app.pendingAction === "list"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 60
                text: "Fetching…"
                font.pixelSize: 34
                font.bold: true
                color: "#555555"
            }
        }

        Rectangle {
            width: 230
            height: 50
            color: "black"
            Text {
                anchors.centerIn: parent
                text: app.logVisible ? "Hide log" : "Show log"
                color: "white"
                font.pixelSize: 22
            }
            MouseArea { anchors.fill: parent; onClicked: app.logVisible = !app.logVisible }
        }

        Rectangle {
            visible: app.logVisible
            width: parent.width
            height: visible ? 200 : 0
            color: "white"
            border.width: 2
            border.color: "black"
            Flickable {
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentWidth: width
                contentHeight: logText.height
                interactive: contentHeight > height
                Text {
                    id: logText
                    width: parent.width
                    text: app.logEntries.length > 0 ? app.logEntries.join("\n") : "No log entries yet."
                    font.pixelSize: 15
                    font.family: "monospace"
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }

    Text {
        visible: app.busy
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 28
        text: "Working…"
        font.pixelSize: 24
    }

    DisplayMethodArea {
        anchors.fill: parent
        displayMethod: DisplayMethodArea.Content
    }
}
