#!/usr/bin/env python3
"""Lightweight settings layout/localization guard: python3 scripts/check-settings.py."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/GooseAgent/GooseAgentApp.swift").read_text()
catalog = json.loads((root / "Resources/Localizable.xcstrings").read_text())["strings"]
layout = source.split("private enum SettingsLayout {", 1)[1].split("\n}", 1)[0]
metrics = dict(re.findall(r"static let (\w+): CGFloat = (\d+)", layout))
assert (metrics["width"], metrics["height"]) == ("810", "660")
assert metrics["sidebarWidth"] == "220"
assert ".defaultSize(width: SettingsLayout.width, height: SettingsLayout.height)" in source
assert "minHeight: SettingsLayout.height" in source
assert ".windowResizability(.contentMinSize)" in source
assert "navigationButton(.about)" in source
assert "NSEvent.removeMonitor(monitor)" in source

settings = source.split("struct SettingsView: View", 1)[1]
assert "Form {" not in settings, "Legacy settings forms returned"
assert ".strokeBorder(Theme.settingsAccent" not in settings, "Blue navigation focus border returned"
assert ".strokeBorder(active ? Color.accentColor" not in settings, "Blue recorder border returned"
assert ".herdrmHideFocusRing()" in settings
assert "SettingsSwitchStyle" in settings and ".menuStyle(.button)" in settings
settings_menu = source.split("private struct SettingsMenu<", 1)[1].split("private struct SettingsButtonStyle", 1)[0]
assert ".pickerStyle(.inline)" in settings_menu, "Settings pickers must show options directly, not nested submenus"
assert source.count("Picker(") == source.count("SettingsMenu(title:"), "Review new settings pickers for nested menus"

titles = set(re.findall(r'SettingsSection\(title: "([^"]+)"', source))
titles.update(("Settings", "Settings…", "Agent Applications", "Font size", "Agent binary path", "Enable %@", "Only checked agents can have shortcuts and other settings."))
assert ".toggleStyle(.checkbox)" in source
assert "AgentKindDisabled" in source
for title in titles:
    for language in ("en", "zh-Hans"):
        value = catalog[title]["localizations"][language]["stringUnit"]["value"]
        assert value.strip(), (title, language)
print("Settings layout and bilingual labels: OK (not a visual acceptance test)")
