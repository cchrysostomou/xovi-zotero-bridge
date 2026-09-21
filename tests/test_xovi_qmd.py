from pathlib import Path
import os
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
                "3.28/zoteroBridgeSettings.qmd",
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
        self.assertIn('run(["check-connection", "--webdav"])', content)
        self.assertIn('"rmapi-repair" : "rmapi-pair"', content)
        self.assertIn(".zotbridge-rmapi-pair-draft.json", content)
        self.assertIn("Sync to Zotero from reMarkable Cloud", content)
        self.assertIn("Paired status:", content)
        self.assertIn('text: bridgeSettings.rmapiPaired ? "Re-pair" : "Pair"', content)
        self.assertIn("reverse_sync_folder: reverseFolderInput.text", content)
        self.assertIn('text: "Zotero/Read"', content)
        self.assertIn("maximumLength: 8", content)
        self.assertIn('rmapiCode.text = "";', content)
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
        self.assertNotIn("api_key", content)
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
