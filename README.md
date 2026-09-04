# TeamKit-M installers

Download one installer for your computer. Unzip it and open the installer
inside; it downloads only the verified TeamKit and CI360 KB components needed
for that platform.

| Computer | Download |
| --- | --- |
| Windows 64-bit | [TeamKit for Windows](bootstrap/TeamKit-Setup-Windows.zip?raw=1) |
| Mac with Apple silicon | [TeamKit for Apple silicon](bootstrap/TeamKit-Setup-macOS-AppleSilicon.zip?raw=1) |
| Mac with Intel processor | [TeamKit for Intel Mac](bootstrap/TeamKit-Setup-macOS-Intel.zip?raw=1) |

The installer prompts for the TeamKit APIM gateway URL and key, then prepares
Claude, Codex, Copilot, Zed, or all supported clients. After setup, open a new
terminal and run `tk`.

Do not download files under `stable/` manually. The installer selects the
correct platform components and verifies their SHA-256 hashes using
`stable/latest.json`.
