# AGENTS.md — FlipStack handoff (LOCAL ONLY, do not push without review)

State snapshot: 2026-11-01. Main repo HEAD == origin/main == `67a102b` (CI success). Website repo `Abla25/flipstack-website` (PRIVATE, public Pages at https://abla25.github.io/flipstack-website/) HEAD == origin == `d52fc2d`. Installed app: `/Applications/FlipStack.app` = receipt demo, build 11.

## Repos & layout
- Main repo `Abla25/FlipStack` (this folder): root = minimal duplex-focused app (`Sources/FlipStack` + `Sources/FlipStackCore`), previous full version preserved in `Advanced/` (standalone package). Tests: `swift test` → 250 tests. CI builds/tests both.
- Demo/receipt app (the one installed on the Mac): `~/Desktop/FlipStack-Demo` — depends on this repo via `.package(path: "../../Documents/Antigravity/FlipStack")` → product `FlipStackCore`. 16 tests. Icon source: `Assets/logo.svg`.
- Website: `~/Desktop/flipstack-site` (private repo `flipstack-website`). Static single page; download button serves the DMG from the MAIN repo release: `https://github.com/Abla25/FlipStack/releases/latest/download/FlipStack-1.0.0.dmg` (release `v1.0.0`; its binary must always equal the installed app). CSP via meta tags (Pages ignores `_headers`). No external requests, no cookies, no web fonts (system fonts only) — GDPR-safe.

## Build / test / install commands
- Main repo: `swift build && swift test` (248+2 tests). Bundle: `BUILD_ARCHS="arm64 x86_64" MARKETING_VERSION=1.0.0 BUILD_NUMBER=<n> Scripts/bundle.sh --dmg`.
- Demo app: `cd ~/Desktop/FlipStack-Demo && swift test && swift build -c release`; install = copy `.build/release/FlipStackDemo` into a `.app` (see Info.plist pattern in shell history: CFBundleIdentifier `app.flipstack.FlipStack`, LSUIElement, icon `Assets/AppIcon.icns` + `menuicon.png`), `codesign --sign - --force`, replace `/Applications/FlipStack.app` (delete old first).
- Headless UI capture (demo, DEBUG flags): `.build/debug/FlipStackDemo --capture /tmp/x.png --state <empty|doc|preview|settings|more|flip|printers|flowdone|select> --open-document /tmp/Sample6.pdf --quit-after 2`.

## KNOWN BUG FIXED LOCALLY (build 10, NOT pushed)
Epson L1800 (ESC/P-R driver): B&W printed in color because the app sent `ColorModel=Gray`, which that PPD does not advertise (its choices are `RGB Mono` — grayscale keyword is `Mono`; HP uses `Gray`). CUPS silently ignores invalid choices → color output. Fix in `~/Desktop/FlipStack-Demo/Sources/FlipStackDemo/Printing.swift`: `colorChoices(for:)` parses `lpoptions -p <queue> -l` color line; `pickGrayscale(from:)` picks gray/grey/mono/black choice (test: `[RGB, Mono] → "Mono"`, HP `[Gray,…] → "Gray"`, fallback `Gray`); `print()` now sends `ColorModel=<picked>` (and `colorKeyword` for color). 16/16 tests. The MAIN repo app already does this correctly via PPD (`AppModel.grayscaleChoice` matches gray/grey/mono/black). TODO when resuming: port the same guard into main-repo `CUPSOptionBuilder`/request path if any hardcoded `ColorModel=Gray` fallback exists there; then commit+push both repos, rebuild DMG, re-upload release asset (keep sha256 in sync on site), bump build.

## Open threads
- Demo package is the shipped UI (receipt). Merging it into the main repo app is the big pending decision.
- `flipstack-site` history still contains one old DMG blob (public build, scanned clean).
- Site repo has an untracked `.DS_Store` (add to .gitignore when next pushing).
