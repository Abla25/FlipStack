# FlipStack Demo (receipt UI) — the app that ships

This folder is the receipt-style menu-bar app that is released as
`FlipStack.app` (v1.0.3, build 14). It is a standalone SwiftPM package that
depends on the root `FlipStackCore` through `.package(path: "..")`.

- **Bundle:** `dist-demo/FlipStack.app` — bundle id `app.flipstack.FlipStack`,
  `LSUIElement` (menu bar, no Dock icon), macOS 14+, arm64.
- **Version (single source of truth):** `Demo/version.env`
  (`MARKETING_VERSION=1.0.3`, `BUILD_NUMBER=14`). The in-app version label and
  the bundle's `Info.plist` are derived from it — no source edits for a bump.
- **Info.plist template:** `Demo/Resources/Info.plist`, rendered by
  `Scripts/bundle-demo.sh` (it also carries `NSBonjourServices` /
  `NSLocalNetworkUsageDescription` for the printer probes).
- **Icons:** `Assets/AppIcon.icns` (app) and
  `Assets/icon.iconset/menuicon.png` (colored brand logo) and `Assets/icon.iconset/menuicon-template.png` (monochrome menu-bar template).
- **Languages:** English + Italiano, switchable in Settings and applied
  immediately.
- **Tests:** 45 (`swift test`).

## Build and test

```sh
cd Demo
swift build -c release
swift test
```

Inside a restricted/agent sandbox the build may need
`swift build -c release --disable-sandbox`; a normal Terminal does not.

## Bundle, sign, DMG

From the repository root:

```sh
Scripts/bundle-demo.sh            # build + assemble + ad-hoc sign
Scripts/bundle-demo.sh --dmg      # ... + dist-demo/FlipStack.dmg + .sha256
```

Artifacts (all gitignored):

- `dist-demo/FlipStack.app` — assembled bundle (binary renamed `FlipStack`,
  `AppIcon.icns` + `menuicon.png` in `Resources`)
- `dist-demo/FlipStack.dmg` — UDZO, volume `FlipStack`, contains the app and an
  `/Applications` symlink
- `dist-demo/FlipStack.dmg.sha256` — `shasum -a 256` of the DMG

The app is **ad-hoc signed and not notarized**; `spctl` rejects it by design and
users need right-click → Open (or System Settings → Privacy & Security → Open
Anyway) on first launch. `--universal` builds arm64 + x86_64 instead of the
default arm64-only.

## Install (local)

Quit the running app, replace the bundle, then launch:

```sh
osascript -e 'quit app "FlipStack"' || true
rm -rf /Applications/FlipStack.app
ditto dist-demo/FlipStack.app /Applications/FlipStack.app
open /Applications/FlipStack.app
```

**Do not change the bundle identifier.** `app.flipstack.FlipStack` is the
UserDefaults domain, the Local Network TCC key and the LaunchServices identity;
changing it would reset the user's settings, printer history and permissions.
The app also namespaces its own preferences under `FlipStack.demo.*` so they
never collide with the older root app's `FlipStack.*` keys.

## Headless UI captures

The Demo supports debug capture flags used by QA:

```sh
.build/release/FlipStack --capture /tmp/panel.png --state settings --quit-after 2
# --state: empty|doc|preview|settings|more|flip|printers|flowdone|select
# --open-document /path/file.pdf ; --simulate-print ; --auto-flow
```

## Releasing

See the repository [`README.md`](../README.md#release-process) ("Release
process"): bump `Demo/version.env`, run `Scripts/bundle-demo.sh --dmg`, commit,
tag `vX.Y.Z`, create the GitHub release with assets **named exactly**
`FlipStack.dmg` and `FlipStack.dmg.sha256` (the website's
`releases/latest/download/FlipStack.dmg` link depends on that name).
