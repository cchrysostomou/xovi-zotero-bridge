import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.ApploadUtils
import net.asivery.CommandExecutor 1.0

Rectangle {
    id: app
    anchors.fill: parent
    color: "#f7f7f7"

    signal close
    function unloading() {}

    property var tags: []
    property var selectedTags: []
    property var items: []
    property var pagination: ({skip: 0, limit: 8, total: 0, has_more: false, next_skip: null})
    property string status: "Loading Zotero tags…"
    property string pendingAction: ""
    property string commandError: ""
    property bool busy: false
    property bool tagsVisible: false
    property int activeIndex: -1
    property string lastQuery: ""
    property int lastSkip: 0
    property string toast: ""

    function run(arguments, action) {
        if (busy) return;
        busy = true;
        pendingAction = action;
        bridgeCommand.output = "";
        bridgeCommand.errorOutput = "";
        bridgeCommand.arguments = [
            "/home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh"
        ].concat(arguments);
        if (!bridgeCommand.startCommand(action === "import" ? 60000 : 30000)) {
            busy = false;
            status = "Could not start bridge command";
        }
    }

    function loadTags(refresh) {
        status = refresh ? "Refreshing Zotero tags…" : "Loading Zotero tags…";
        run(refresh ? ["tags", "--refresh", "--json"] : ["tags", "--json"], "tags");
    }

    function listArguments(skip) {
        var args = ["list", "--page-info", "--limit", String(pagination.limit),
                    "--skip", String(skip), "--query", searchInput.text];
        for (var i = 0; i < selectedTags.length; i++) {
            args.push("--tag");
            args.push(selectedTags[i]);
        }
        return args;
    }

    function loadPage(skip) {
        lastQuery = searchInput.text;
        lastSkip = skip;
        status = "Loading Zotero papers…";
        run(listArguments(skip), "list");
    }

    function refreshCurrentPage() {
        loadPage(lastSkip);
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
            return query.length === 0 || tag.toLowerCase().indexOf(query) !== -1;
        });
    }

    function itemSubtitle(item) {
        var parts = [];
        if (item.year) parts.push(item.year);
        parts.push(item.has_pdf ? "PDF" : "No PDF");
        if (item.mapping) parts.push("on reMarkable");
        if (item.attempt) parts.push("attempt pending");
        return parts.join("  ·  ");
    }

    function importItem(item, index) {
        if (!item || !item.item_key || !item.has_pdf) {
            toast = "No stored PDF available for this item";
            return;
        }
        activeIndex = index;
        status = "Importing " + item.item_key + "…";
        run(["import", "--item-key", item.item_key], "import");
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
            return;
        }
        commandError = "";
        if (Array.isArray(result)) {
            tags = result;
            status = "Loaded " + result.length + " tags";
            loadPage(0);
            return;
        }
        if (bridgeCommand.exitCode !== 0 || result.ok !== true) {
            status = "Bridge error: " + (result.error || "command exited " + bridgeCommand.exitCode);
            return;
        }
        if (pendingAction === "list") {
            items = result.items || [];
            pagination = result.pagination || pagination;
            status = "Showing " + items.length + " of " + pagination.total + " papers";
        } else if (pendingAction === "import") {
            toast = "Imported " + (result.item_key || "paper") + " to reMarkable";
            status = toast;
            activeIndex = -1;
            refreshCurrentPage();
        } else {
            status = "Command complete";
        }
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

    Component.onCompleted: loadTags(false)

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
            text: app.status
            font.pixelSize: 22
            wrapMode: Text.WordWrap
        }

        Row {
            width: parent.width
            spacing: 14
            Rectangle {
                width: parent.width - 480
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
                    Keys.onReturnPressed: app.loadPage(0)
                    Keys.onEnterPressed: app.loadPage(0)
                }
            }
            Rectangle {
                width: 210
                height: 64
                color: app.busy ? "#aaaaaa" : "black"
                Text { anchors.centerIn: parent; text: "Search"; color: "white"; font.pixelSize: 24 }
                MouseArea { anchors.fill: parent; enabled: !app.busy; onClicked: app.loadPage(0) }
            }
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
        }

        Text {
            width: parent.width
            text: app.selectedTags.length === 0 ? "No tag filter selected" :
                  "Tags: " + app.selectedTags.join(", ")
            font.pixelSize: 20
            wrapMode: Text.WordWrap
        }

        Rectangle {
            visible: app.tagsVisible
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
                            id: tagSearch
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            font.pixelSize: 21
                            selectByMouse: true
                            verticalAlignment: TextInput.AlignVCenter
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
                    height: parent.height - 70
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

        Row {
            width: parent.width
            spacing: 16
            Rectangle {
                width: 190
                height: 60
                color: (!app.busy && app.pagination.skip > 0) ? "black" : "#aaaaaa"
                Text { anchors.centerIn: parent; text: "Previous"; color: "white"; font.pixelSize: 22 }
                MouseArea {
                    anchors.fill: parent
                    enabled: !app.busy && app.pagination.skip > 0
                    onClicked: app.loadPage(Math.max(0, app.pagination.skip - app.pagination.limit))
                }
            }
            Text {
                width: parent.width - 412
                height: 60
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                text: "Page offset " + app.pagination.skip + " / " + app.pagination.total
                font.pixelSize: 22
            }
            Rectangle {
                width: 190
                height: 60
                color: (!app.busy && app.pagination.has_more) ? "black" : "#aaaaaa"
                Text { anchors.centerIn: parent; text: "Next"; color: "white"; font.pixelSize: 22 }
                MouseArea {
                    anchors.fill: parent
                    enabled: !app.busy && app.pagination.has_more
                    onClicked: app.loadPage(app.pagination.next_skip)
                }
            }
        }

        Rectangle {
            width: parent.width
            height: parent.height - y - 20
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
                    Repeater {
                        model: app.items
                        delegate: Rectangle {
                            width: paperList.width
                            height: 128
                            color: index === app.activeIndex ? "#dddddd" : "white"
                            border.width: 1
                            border.color: "#555555"
                            Column {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8
                                Text {
                                    width: parent.width
                                    text: modelData.title || modelData.item_key
                                    font.pixelSize: 24
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: app.itemSubtitle(modelData)
                                    font.pixelSize: 18
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: "Long-press to import  ·  " + modelData.item_key
                                    font.pixelSize: 16
                                    color: modelData.has_pdf ? "black" : "#777777"
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onPressAndHold: app.importItem(modelData, index)
                            }
                        }
                    }
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
        displayMethod: DisplayMethodArea.Fast
    }
}
