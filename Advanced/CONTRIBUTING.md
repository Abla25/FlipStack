# Contributing to FlipStack

Thanks for helping make manual duplex less error-prone. This project is a small, focused macOS app, and contributions of all sizes are welcome: code, tests, documentation, PPD fixtures, and hardware reports.

## Before you start

- Read the [README](README.md) and, for changes to the print flow, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Search existing issues before opening a new one.
- Keep changes focused. A pull request should solve one problem and include the tests or documentation that make it reviewable.
- By contributing, you agree that your work is licensed under the project's [MIT License](LICENSE).

## Requirements

- macOS 13 Ventura or later
- Xcode 15 or later
- Swift 5.9 or later
- A printer configured in macOS for end-to-end print testing, when your change touches the print path

No third-party runtime dependencies are used, and new ones should not be introduced without prior maintainer agreement.

## Build and test

From the repository root:

```sh
swift build
swift test
swift test --parallel
Scripts/bundle.sh
open dist/FlipStack.app
```

`Scripts/bundle.sh` creates an ad-hoc signed development app in `dist/FlipStack.app`. It also generates the app icon if it is missing. It does not notarize anything.

Useful checks before opening a pull request:

```sh
swift build -c release
swift test --parallel
Scripts/bundle.sh
plutil -lint Resources/Info.plist
plutil -lint Resources/FlipStack.entitlements
bash -n Scripts/bundle.sh
bash -n Scripts/make-icon.sh
```

For a universal local build:

```sh
BUILD_ARCHS="arm64 x86_64" Scripts/bundle.sh
```

When you change `Resources/AppIcon.svg`, regenerate the committed `.icns` so Finder and the app bundle use the same artwork:

```sh
Scripts/make-icon.sh
```

## Tests and fixtures

- Tests belong in `Tests/FlipStackCoreTests`, grouped by the area they cover.
- Core behavior should be testable without a printer. Use the existing spooler, PPD, and status protocols to inject deterministic fakes.
- PPD fixtures belong in `Tests/FlipStackCoreTests/Fixtures/PPDs`. They are copied by SwiftPM as test resources.
- Keep fixtures small and public. Do not include real serial numbers, hostnames, user names, email addresses, or other personal data.
- Do not commit a printer's complete live PPD without checking it for identifying information first.
- Do not edit fixtures only to make a failing test pass. Fix the production behavior or explain why the fixture is wrong.
- Changes to page ordering, the duplex state machine, or booklet imposition need regression tests. These are the areas where a small mistake ruins a printed document.
- If you add a test that needs a real printer, mark it clearly as a manual hardware check instead of making the automated suite depend on hardware.

## Code style

- Use Swift 5.9 language features and keep the package's deployment target at macOS 13.
- Follow the style of the surrounding code. Prefer clear names over abbreviations.
- Keep UI code on the main actor and keep `FlipStackCore` independent of AppKit and SwiftUI.
- Keep print-system access behind the existing protocols. Do not scatter `Process` calls or shell strings through views.
- Use clear English in source comments, UI copy, commit messages, and documentation.
- Comments should explain why a decision was made, especially around page order, flip direction, or job-state handling. Avoid comments that only restate the code.
- Do not add third-party dependencies for small conveniences. The project deliberately builds with the macOS SDK alone.
- Preserve accessibility. New controls need sensible labels and must respect Reduce Motion and both light and dark appearance.
- Avoid force-unwrapping values that come from the printer, PPD, filesystem, or process output. Return a typed error or a safe fallback instead.
- Never log document contents, full paths containing user names, or printer credentials.
- Screenshots belong in `docs/screenshots` and keep the names `empty.png`, `ready.png`, `preview.png`, `flip.png`, `printing.png`, `booklet.png`, and `queue.png`. Render the real panel at its normal size, use a fictional document title, and remove printer names, serial numbers, and personal data.

## Pull request checklist

- [ ] The change is scoped to one problem and has a clear description.
- [ ] `swift build` succeeds.
- [ ] `swift test --parallel` passes.
- [ ] `Scripts/bundle.sh` produces a launchable app.
- [ ] `Info.plist` and entitlements still pass `plutil -lint`.
- [ ] New behavior has tests, or the pull request explains why a test is not practical.
- [ ] Print-path changes have been exercised on real hardware, with the printer model and connection type named in the pull request.
- [ ] VoiceOver, Reduce Motion, light appearance, and dark appearance have been checked for UI changes.
- [ ] Documentation and screenshots are updated when behavior or wording changes.
- [ ] No build products, DMGs, certificates, provisioning profiles, or secrets are included.
- [ ] The change contains no unrelated formatting churn.

## Hardware notes

Print-path changes need more than a successful build. In the pull request, include:

- Printer model and firmware version, if known
- Connection: USB, network, or another transport
- macOS version
- Queue name (redact anything personal) and PPD source
- Whether the output tray ejects pages face-up or face-down
- The document used for the check: page count, simplex or booklet, and single or multiple copies
- What happened on the fronts pass and on the backs pass

Use plain paper and a short document for initial checks. Never run destructive or high-volume tests on a printer you do not control. If a test could consume a lot of ink or paper, ask first.

A useful hardware report describes the observed CUPS state as well as the paper result. Commands such as `lpstat -p -d` and `lpstat -o` are usually enough. Before posting, remove queue names, job titles, owner names, device URIs, serial numbers, hostnames, and any other identifying details.

## Releases and notarization

Releases are built by maintainers from the release workflow. The workflow uses Developer ID signing and Apple notarization credentials stored as repository secrets. These secrets are maintainer-only:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `APPLE_SIGNING_IDENTITY` (optional; otherwise the workflow discovers the Developer ID Application identity)

Never ask for, paste, or commit these values in an issue, pull request, log, or screenshot. Do not run the notarization workflow from a fork. Local builds are ad-hoc signed and are not release artifacts.

Release tags use the `v` prefix, for example `v1.0.0`. Maintainers should let the release workflow build and notarize the release rather than uploading a hand-built DMG.

## Questions and reports

Use the repository's issue templates for bugs and feature requests. For a printing problem, include the details listed under hardware notes. For a security-sensitive report, contact a maintainer privately rather than opening a public issue.
