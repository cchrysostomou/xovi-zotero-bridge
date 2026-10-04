from pathlib import Path
import os
import re
import shutil
import subprocess
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def run_powershell_script(script):
    if os.name == "nt":
        command = ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(script)]
        return subprocess.run(
            command, check=True, cwd=ROOT, capture_output=True, text=True)
    command = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File",
               subprocess.check_output(["wslpath", "-w", str(script)],
                                       text=True).strip()]
    return subprocess.run(command, check=True, capture_output=True, text=True)


class ZoteroQuickSyncQmdTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node"), "AppLoad JavaScript test requires Node.js")
    def test_appload_stops_loading_until_first_run_setup_is_saved(self):
        content = (ROOT / "xovi" / "appload" / "zotero-library" / "ui" /
                   "ZoteroLibrary.qml").read_text()
        match = re.search(r"^    function finishCommand\(\) \{.*?^    \}",
                          content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match)
        script = r'''
const assert = require("node:assert/strict");
let busy=true, pendingAction="settings", status="", commandError="";
let pagination={limit:8}, calls=[], logs=[];
const bridgeCommand={exitCode:0, output:JSON.stringify({ok:true,configured:false})};
function appendLog(message) { logs.push(message); }
function loadTags(refresh) { calls.push(refresh); }
finishCommand();
assert.equal(busy, false);
assert.match(status, /Settings > Zotero Bridge/);
assert.deepEqual(calls, []);
bridgeCommand.output=JSON.stringify({ok:true,configured:true,list_page_limit:12});
finishCommand();
assert.deepEqual(calls, [false]);
assert.equal(pagination.limit, 12);
bridgeCommand.exitCode=1;
bridgeCommand.output=JSON.stringify({ok:false,error:"configuration_error",message:"Invalid configuration syntax on line 3"});
finishCommand();
assert.match(status, /line 3/);
assert.deepEqual(calls, [false]);
'''
        result = subprocess.run([shutil.which("node"), "-e", match.group() + "\n" + script],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Settings JavaScript test requires Node.js")
    def test_first_run_settings_javascript_flow(self):
        content = (ROOT / "xovi" / "3.28" / "zoteroBridgeSettings.qmd").read_text()
        functions = []
        for name in ("finishCommand", "saveSettings", "testConnection"):
            match = re.search(r"^ {20}function " + name + r"\([^)]*\) \{.*?^ {20}\}",
                              content, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        script = r'''
const assert = require("node:assert/strict");
let busy = false, configured = false, settings = {}, useWebdav = false, libraryType = "user";
let status = "", queueTag = "", syncedTag = "", tags = [], collections = [], events = [];
let pendingKind = "settings";
const settingsCommand = {output:"", exitCode:0};
const field = () => ({text:""});
const libraryIdInput = field(), apiKeyInput = field(), apiKeyHint = field();
const urlInput = field(), usernameInput = field(), passwordInput = field(), passwordHint = field();
const folderInput = field(), reverseFolderInput = field(), listPageLimitInput = field();
let calls = [], sent = [], pendingRequest;
function run(args) { calls.push(args); }
const bridgeSettings = {run};
Object.defineProperty(bridgeSettings, "busy", {get:() => busy, set:value => busy=value});
Object.defineProperty(bridgeSettings, "status", {get:() => status, set:value => status=value});
class XMLHttpRequest {
    static DONE = 4;
    open(method, path) { this.method=method; this.path=path; pendingRequest=this; }
    send(body) { sent.push(JSON.parse(body)); }
}
function load(configuredValue, storage) {
    settingsCommand.output = JSON.stringify({
        ok:true, configured:configuredValue,
        configuration_message:configuredValue ? "" : "Enter Zotero credentials",
        zotero:{library_id:configuredValue ? "123" : "", library_type:"user", api_key_set:configuredValue},
        webdav:{enabled:storage, url:"", username:"", password_set:configuredValue},
        default_target_folder:"Zotero/unread", reverse_sync_folder:"Zotero/Read",
        sync_queue_tag:"to_sync", sync_synced_tag:"synced", list_page_limit:8
    });
    finishCommand();
}
load(false, false);
assert.equal(configured, false);
assert.deepEqual(calls, []);
assert.equal(folderInput.text, "Zotero/unread");
testConnection();
assert.match(status, /Save/);
assert.deepEqual(calls, []);
libraryIdInput.text="123"; apiKeyInput.text="new-key"; passwordInput.text="new-password";
saveSettings();
assert.equal(busy, true);
assert.equal(apiKeyInput.text, "");
assert.equal(passwordInput.text, "");
assert.equal(sent[0].api_key, "new-key");
assert.equal(sent[0].use_webdav, false);
assert.equal(sent[0].library_id, "123");
pendingRequest.readyState=XMLHttpRequest.DONE;
pendingRequest.status=0;
pendingRequest.onreadystatechange();
assert.deepEqual(calls, [["settings-apply"]]);
assert.equal(busy, false);
calls=[];
load(true, false);
assert.equal(apiKeyInput.text, "");
assert.deepEqual(calls, [["tags", "--json"]]);
calls=[];
testConnection();
assert.deepEqual(calls, [["check-connection"]]);
calls=[];
load(true, true);
calls=[];
testConnection();
assert.deepEqual(calls, [["check-connection", "--webdav"]]);
settingsCommand.output=JSON.stringify({ok:true,metadata:"accessible",storage:"zotero",pdf_download:"not_tested"});
finishCommand();
assert.match(status, /PDF access has not been tested/);
settingsCommand.exitCode=1;
settingsCommand.output=JSON.stringify({ok:false,error:"settings_error",message:"Invalid setting: library_id"});
finishCommand();
assert.match(status, /library_id/);
settingsCommand.exitCode=0;
const before=sent.length;
listPageLimitInput.text="0";
saveSettings();
assert.equal(sent.length, before);
assert.match(status, /integer/);
'''
        result = subprocess.run([shutil.which("node"), "-e", "\n".join(functions) + "\n" + script],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_supported_firmware_patches_have_identical_wired_action(self):
        patches = [
            ROOT / "xovi" / version / "zoteroQuickSync.qmd"
            for version in ("3.27", "3.28")
        ]
        contents = [patch.read_text(encoding="utf-8") for patch in patches]
        for content in contents:
            self.assertIn("IMPORT net.asivery.CommandExecutor", content)
            self.assertIn("AsyncCommandExecutor", content)
            self.assertIn('command: "sh"', content)
            self.assertIn('"sync-all"', content)
            self.assertIn('text: "Z"', content)
            self.assertIn("radius: width / 2", content)
            self.assertIn("startCommand(30000)", content)
            self.assertIn("onStdOutAvailable", content)
            self.assertIn("onRunningChanged", content)
            self.assertIn("JSON.parse(stdout)", content)
            self.assertIn("LOCATE AFTER [[7712155293725601]]", content)
            self.assertNotIn("api_key", content)
            self.assertNotIn("webdav_password", content)
        self.assertEqual(
            contents[0][contents[0].index("SLOT"):],
            contents[1][contents[1].index("SLOT"):],
        )

    def test_qmd_package_contains_only_installable_ui_files(self):
        run_powershell_script(ROOT / "scripts" / "package-xovi-quick-settings.ps1")
        package = ROOT / "dist" / "xovi-zotero-quick-settings-qmd.zip"
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(set(archive.namelist()), {
                "README.md", "3.27/zoteroQuickSync.qmd", "3.28/zoteroQuickSync.qmd",
                "3.28/zoteroBridgeSettings.qmd", "3.28/zoteroSendToZotero.qmd",
            })
            for name in archive.namelist():
                self.assertNotIn("\r", archive.read(name).decode("utf-8"))
            self.assertNotIn("config.toml", archive.namelist())

    def test_appload_app_uses_existing_bridge_commands(self):
        qml = (ROOT / "xovi" / "appload" / "zotero-library" / "ui" /
               "ZoteroLibrary.qml").read_text()
        manifest = (ROOT / "xovi" / "appload" / "zotero-library" /
                    "manifest.json").read_text()
        self.assertIn('"loadsBackend": false', manifest)
        self.assertIn('"entry": "/ui/ZoteroLibrary.qml"', manifest)
        self.assertIn("signal close", qml)
        self.assertIn("function unloading()", qml)
        self.assertIn("import net.asivery.CommandExecutor 1.0", qml)
        self.assertIn("AsyncCommandExecutor", qml)
        self.assertIn("/home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh", qml)
        self.assertIn('"list", "--page-info"', qml)
        self.assertIn('"tags", "--refresh", "--json"', qml)
        self.assertIn('"import", "--item-key"', qml)
        self.assertIn("selectedTags", qml)
        self.assertIn("pageCount()", qml)
        self.assertIn("currentPage()", qml)
        self.assertIn("onClicked: app.tapItem", qml)
        self.assertIn("onPressAndHold: app.selectAllAttachmentsForItem", qml)
        self.assertIn("app.toggleAttachmentSelection", qml)
        self.assertIn("app.startBatchDownload", qml)
        self.assertIn("app.logVisible = !app.logVisible", qml)
        self.assertIn('"Hide log" : "Show log"', qml)
        self.assertIn("appendLog(", qml)
        self.assertIn("app.itemRemarkablePath", qml)
        self.assertIn('"On reMarkable: "', qml)
        self.assertIn('color: "#0000ee"', qml)
        self.assertIn('"children", "--item-key"', qml)
        self.assertIn("--attachment-key", qml)
        self.assertIn("--include-zotero-tags", qml)
        self.assertIn("--add-unread-tag", qml)
        self.assertNotIn("api_key", qml)
        self.assertNotIn("webdav_password", qml)

    def test_appload_package_contains_only_installable_app_files(self):
        run_powershell_script(ROOT / "scripts" / "package-xovi-appload.ps1")
        package = ROOT / "dist" / "xovi-zotero-appload-app.zip"
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(set(archive.namelist()), {
                "zotero-library/manifest.json",
                "zotero-library/icon.png",
                "zotero-library/resources.rcc",
            })
            self.assertGreater(len(archive.read("zotero-library/resources.rcc")), 1000)
            self.assertNotIn("config.toml", archive.namelist())

    def test_328_settings_page_uses_safe_bridge_contract(self):
        content = (ROOT / "xovi" / "3.28" / "zoteroBridgeSettings.qmd").read_text()
        self.assertIn('text: "Zotero Bridge"', content)
        self.assertIn('~&8399601734642709923&~: ~&"5203945921812648813&~', content)
        self.assertIn('run(["settings", "--json"])', content)
        self.assertIn('run(["settings-apply"])', content)
        self.assertIn('run(["tags", "--refresh", "--json"])', content)
        self.assertIn('run(["activity-log"])', content)
        self.assertIn('run(["clear-activity-log"])', content)
        self.assertIn('status = "Cleared " + result.cleared + " log events"', content)
        self.assertIn('["check-connection", "--webdav"] : ["check-connection"]', content)
        self.assertIn("bridgeSettings.testConnection()", content)
        self.assertIn("bridgeSettings.configured", content)
        self.assertIn("Sync to Zotero from reMarkable Cloud", content)
        self.assertIn("reverse_sync_folder: reverseFolderInput.text", content)
        self.assertIn('text: "Zotero/Read"', content)
        self.assertNotIn("rmapi", content)
        self.assertNotIn("Pair", content)
        self.assertIn("openTagPicker", content)
        self.assertIn("Repeater", content)
        self.assertIn("bridgeSettings.tags", content)
        self.assertIn("property string errorOutput", content)
        self.assertIn("onStdErrAvailable: function(chunk) { errorOutput += chunk; }", content)
        self.assertIn("Bridge command failed (exit ", content)
        self.assertIn("contentHeight: eventText.height", content)
        self.assertIn("events = result.entries.slice().reverse();", content)
        self.assertIn("event.retained_in_source", content)
        self.assertIn("settingsCommand.output.length", content)
        self.assertLess(content.index("if (Array.isArray(result))"),
                        content.index("result.ok !== true"))
        self.assertIn('model: ["All", "#", "A"', content)
        self.assertIn("bridgeSettings.visibleTags()", content)
        self.assertIn("contentHeight: availableTags.height", content)
        self.assertIn("bridgeSettings.filteredTags()", content)
        self.assertIn("id: queueInput", content)
        self.assertIn("id: syncedInput", content)
        self.assertIn('bridgeSettings.openTagPicker = "queue"', content)
        self.assertIn('bridgeSettings.openTagPicker = "synced"', content)
        self.assertIn("property bool tagsVisible: false", content)
        self.assertIn('"Hide tags" : "Show tags"', content)
        self.assertIn('text: "Save settings"', content)
        self.assertIn('text: "Test Zotero connection"', content)
        self.assertIn('text: "Refresh tags"', content)
        self.assertIn("password_set", content)
        self.assertIn("id: apiKeyInput", content)
        self.assertIn("draft.api_key = apiKeyInput.text", content)
        self.assertIn("apiKeyInput.text = \"\"", content)
        self.assertIn("result.zotero.api_key_set", content)
        self.assertIn("library_id: libraryIdInput.text", content)
        self.assertIn("library_type: libraryType", content)
        self.assertIn("use_webdav: useWebdav", content)
        self.assertIn('model: ["Zotero Storage", "WebDAV"]', content)
        self.assertIn("if (!result.applied && configured)", content)
        self.assertIn("result.message || result.error", content)
        self.assertNotIn("result.zotero.api_key;", content)
        self.assertNotIn('webdav_password: "', content)

    def test_windows_update_script_deploys_runtime_and_328_qmd_files(self):
        content = (ROOT / "scripts" / "update-remarkable.ps1").read_text()
        self.assertIn('$TargetHost = "192.168.1.33"', content)
        self.assertIn("package-tablet.ps1", content)
        self.assertIn("package-xovi-quick-settings.ps1", content)
        self.assertIn("package-xovi-appload.ps1", content)
        self.assertIn('unzip -oq "$stage/xovi-zotero-library-aarch64.zip" -d "$bridge"', content)
        self.assertIn('"$bridge/bin/7zz"', content)
        self.assertIn('cp "$stage/qmd/3.28/zoteroQuickSync.qmd"', content)
        self.assertIn('cp "$stage/qmd/3.28/zoteroBridgeSettings.qmd"', content)
        self.assertIn('unzip -oq "$stage/xovi-zotero-appload-app.zip" -d "$stage/appload"', content)
        self.assertIn('cp -R "$stage/appload/zotero-library" "$appload/zotero-library"', content)
        self.assertNotIn('cp "$stage/config.toml"', content)


if __name__ == "__main__":
    unittest.main()
