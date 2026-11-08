# Agent instructions

Read `CONTRIBUTING.md` for layout, test patterns, and how to render the UI.

- Run `swift test --skip KeychainTokenTests` before calling work done. On macOS 27 prefix it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select -p` points at CommandLineTools.
- Don't run `swift run PopoverSnapshot out.png` with `light` or `dark`: those use the user's real GitHub login. Use the fixture modes (`overview`, `drilldown`, `menubar`, `rollover`, `milestone`).
- Don't run `./scripts/install.sh` unless asked: it replaces and relaunches the user's installed app.
- User-visible behavior changes update `README.md` in the same change.
