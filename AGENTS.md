# AGENTS.md — FlipStack handoff (LOCAL ONLY, do not push without review)

State snapshot: **2026-11-04**, v1.0.2 (build 13) release published — tag `v1.0.2`, GitHub release assets `FlipStack.dmg` + `FlipStack.dmg.sha256`, website updated.
This file describes the *actual* current state; older snapshots in git history
are stale (they said HEAD `67a102b`, installed build 11, site HEAD `d52fc2d`).

## Repos & where things live

- **Main repo:** `~/Documents/Antigravity/FlipStack` → `github.com/Abla25/FlipStack`
  (PUBLIC, branch `main`). Last pushed commit: the v1.0.2 release commit on `main` (tag `v1.0.2`). v1.0.2 was prepared with `Scripts/bundle-demo.sh`; DMG sha256 `e9e72ed29025d9a3b4bb9a7966aeb23ddf51109055f6f9fd21a7ff2ce8c8f40c`.
- **Website repo:** `~/Desktop/flipstack-site` → `github.com/Abla25/flipstack-website`
  (PRIVATE). Local git remote still points at the pre-rename
  `https://github.com/Abla25/Abla25.github.io.git` — it works via GitHub's
  rename redirect, but fix it with `git remote set-url origin
  https://github.com/Abla25/flipstack-website.git`.
  - Pages: <https://abla25.github.io/flipstack-website/> — built from `main`,
    repository root, legacy build type; push = automatic redeploy (~1 min).
- **Installed app:** `/Applications/FlipStack.app` — at snapshot time the
  **v1.0.1 build 12** receipt Demo (ad-hoc signed, arm64). It is replaced only
  during a release install.

## What actually ships

The product users download is the **receipt-style Demo app in `Demo/`**, not the
root `Sources/FlipStack` app.

- Bundle: `FlipStack.app`, **CFBundleIdentifier `app.flipstack.FlipStack`**
  (never change it — see Persistence below), `LSUIElement` menu-bar app,
  `LSMinimumSystemVersion 14.0`, **arm64-only**, ad-hoc signed, **not notarized**.
- Version: single source of truth [`Demo/version.env`](Demo/version.env)
  (`MARKETING_VERSION=1.0.2`, `BUILD_NUMBER=13`). The bundle's `Info.plist` is
  rendered from [`Demo/Resources/Info.plist`](Demo/Resources/Info.plist) by the
  bundle script (placeholders `__VERSION__` / `__BUILD__`); the in-app version
  label reads it back from the bundle, so **no source edit is needed to bump**.
- `Demo/Resources/Info.plist` also declares `NSBonjourServices`
  (`_ipp._tcp`, `_ipps._tcp`, `_pdl-datastream._tcp` — the types
  `Demo/Sources/FlipStackDemo/NetworkProbe.swift` browses) and
  `NSLocalNetworkUsageDescription` for the printer probes.
- Languages: English + Italiano (in-app switch in Settings; tables in
  `Demo/Sources/FlipStackDemo/Localization.swift`).
- Tests: Demo 96 (`cd Demo && swift test`), root/engine 250 (1 live-CUPS test
  skipped without a reachable printer), `Advanced/` 248.

## Build / package / test commands

```sh
# the shipped app — build + assemble + ad-hoc sign (+ DMG + sha256):
Scripts/bundle-demo.sh            # → dist-demo/FlipStack.app
Scripts/bundle-demo.sh --dmg      # → + dist-demo/FlipStack.dmg + .sha256
#   flags: --unsigned (CI artifacts), --universal (arm64+x86_64), --help
#   env:   MARKETING_VERSION / BUILD_NUMBER (override Demo/version.env),
#          OUT_DIR, SWIFT_BUILD_FLAGS, DMG_ENGINE=auto|hdiutil|hybrid

# app build/test directly:
cd Demo && swift build -c release && swift test      # 96 tests

# root engine + root app; advanced:
swift build && swift test                            # 250 tests
cd Advanced && swift build && swift test             # 248 tests
```

**Sandbox notes (DSH agent harness):** plain `swift build`/`swift test` fail
with a sandbox error — append `--disable-sandbox` (the bundle script retries
automatically). `hdiutil create -srcfolder` is blocked ("Directory non vuota" /
"Operazione non consentita"); the script detects that and falls back to a
validated `makehybrid → UDRW → UDZO` round-trip that strips the FinderInfo
xattrs which would otherwise break the code signature (`DMG_ENGINE=hybrid` to
force it). Writes to `/Applications`, `gh` write calls and `ps`/TCC reads are
also outside the sandbox: the release *build* runs fine in the sandbox, the
*install* and *publish* steps need a normal Terminal.
Multiple agents building `Demo/` concurrently contend on `Demo/.build`'s SwiftPM
lock and queue behind each other — avoid parallel Demo builds.

## Release / deploy checklist (vX.Y.Z, build N)

1. **Bump** `Demo/version.env`; update `Demo/README.md`/docs if needed. Commit.
2. **Build/package:** `Scripts/bundle-demo.sh --dmg` (add `--universal` only if
   Intel support is wanted).
3. **Verify:** `plutil` version/build of the bundle, `codesign --verify
   --deep --strict`, `shasum -a 256 -c dist-demo/FlipStack.dmg.sha256`, mount
   the DMG (app + `/Applications` symlink present), headless smoke:
   `dist-demo/FlipStack.app/Contents/MacOS/FlipStack --capture /tmp/v.png
   --state settings --quit-after 2` → `CAPTURED`.
4. **Tag:** `git tag -a vX.Y.Z -m "FlipStack X.Y.Z (build N)"` and
   `git push origin main vX.Y.Z`. **Tags publish nothing** — the `Release`
   workflow is manual-only (`workflow_dispatch`) and only uploads CI artifacts.
5. **GitHub release:** assets MUST be named exactly **`FlipStack.dmg`** and
   **`FlipStack.dmg.sha256`** (the website uses
   `releases/latest/download/FlipStack.dmg`; `/releases/latest` = newest
   non-draft, non-prerelease release). Draft-first is safest:
   `gh release create vX.Y.Z --draft --verify-tag --title "FlipStack X.Y.Z
   (build N)" --notes-file notes.md`, `gh release upload vX.Y.Z
   dist-demo/FlipStack.dmg dist-demo/FlipStack.dmg.sha256`, verify, then
   `gh release edit vX.Y.Z --draft=false`.
6. **Website** (`~/Desktop/flipstack-site`): update `index.html` version labels
   + size, replace `FlipStack.dmg.sha256` with the new hash, keep the download
   href unchanged (`assets/app.js` already fetches `FlipStack.dmg.sha256` and
   displays the bare hash after the v1.0.2 fix — verify it), then commit +
   push `main` and wait for the Pages build (`gh api
   repos/Abla25/flipstack-website/pages/builds/latest`).
7. **Verify live:** curl the public download URL, compare sha, curl the site
   sha file and `assets/app.js`, `grep` the version labels; then install on the
   Mac (backup `/Applications/FlipStack.app` first, quit the running app,
   `ditto` the new bundle) and re-run the headless smoke test.

## Persistence / TCC / bundle identity (do not break)

- Bundle id **`app.flipstack.FlipStack`** is the UserDefaults domain, the
  **Local Network** TCC key and the LaunchServices identity. Changing it resets
  settings/printer history and re-prompts for network access.
- The Demo namespaces its preferences under **`FlipStack.demo.*`**
  (`schemaVersion`, `settings.v1`, `printerOptions.v1`, `lastPrinterID` — see
  `Demo/Sources/FlipStackDemo/SettingsStore.swift`). The older root app's
  `FlipStack.*` keys (e.g. `FlipStack.printerOptions.v1`, `FlipStack.language`)
  stay in the domain and must **never** be reused/reinterpreted by the Demo.
- `NetworkProbe` does Bonjour browsing + TCP to printers → macOS Local Network
  permission prompt; an ad-hoc signature change can re-prompt. No login items,
  no SMAppService, no Keychain, not sandboxed.
- Uninstall: quit + Trash the app; reset with
  `defaults delete app.flipstack.FlipStack` and
  `tccutil reset All app.flipstack.FlipStack` if desired.

## Known traps / stale things

- **`release.yml` is now manual-only** (was tag-triggered and always failed at
  "Validate release secrets"; it built the root app universal/notarized under a
  versioned asset name that the site can't use). Do not re-add a tag trigger
  unless you also retarget it to `Demo/` and the stable `FlipStack.dmg` name.
- CI has a `demo` job that builds/tests `Demo/` and verifies the bundled app +
  DMG; the `build` job still covers root + Advanced.
- Release asset name stability is a contract: never rename `FlipStack.dmg`
  (versioned names break the site's `releases/latest/download` link).
- `dist/` contains an old root-app `FlipStack-1.0.0.dmg` (gitignored, untracked,
  never released — safe to delete). `dist-demo/` is gitignored build output.
- Old tags are lightweight: `v1.0.0` → `bab9490`, `v1.0.1` → `67a102b`; the
  v1.0.1 tag predates `Demo/`, so that release is not reproducible from its tag.
  v1.0.2+ is reproducible via `Demo/version.env` + `Scripts/bundle-demo.sh`.
- Site repo: `.DS_Store` is still tracked and there is no `.gitignore`; the
  deploy-prep files/commands for the v1.0.2 fix live in
  `/tmp/website-prep/` (apply + untrack in the same commit).
- Do not rely on `spctl` accepting the app: ad-hoc signed apps are "rejected"
  by design; use `codesign --verify` and the sha256 instead.

## Open threads

- **v1.0.2 deployed** from this commit: installed app `/Applications/FlipStack.app`
  = release asset (same bytes), site deployed at
  <https://abla25.github.io/flipstack-website/>. `v1.0.3+` follows the same
  script + checklist.
- Intel support: default build is arm64-only; `--universal` exists but the
  website says Apple silicon. Decide whether v1.0.3+ ships universal.
- Notarization requires a paid Apple Developer account; until then the app
  stays ad-hoc signed with the right-click → Open flow.
- Possible later improvement: generate the site's version/sha values from
  `Demo/version.env` (e.g. a `version.json` the site fetches) so labels can't
  drift.
