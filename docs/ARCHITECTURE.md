# FlipStack Architecture

FlipStack is a menu-bar macOS utility that turns a simplex printer into a manual-duplex printer, while also handling ordinary single-sided jobs. It prints a PDF in two CUPS passes: odd pages, a physical whole-block flip by the user, then even pages. Booklet mode imposes saddle-stitch signatures into separate fronts/backs page sequences and prints them 2-up. The reference device is the Epson L1800: A3+ photo printer, simplex only, face-up output.

FlipStack is a coordinator, not a print driver. CUPS rasterizes and talks to the device; FlipStack selects pages, builds `lp` requests, monitors real job state, and asks the user for the one operation software cannot perform. Constraints: macOS 13+, Swift 5.9, SwiftPM, MIT, stock CUPS queues, no root, no kernel extension, no custom backend, one duplex flow at a time, and no cloud upload. PDF bytes are sent only to the CUPS queue/printer selected by the user, which may be a network device.

Implementation status: complete end-to-end. The models and protocols in `Sources/FlipStackCore` are the source of truth. `CUPSClient`, `PPDLoader`, `IPPStatusClient`, `BookletImposer`, and `DuplexOrchestrator` implement those contracts; the SwiftUI menu-bar shell and services live in `Sources/FlipStack`. The test suite exercises the flow with injected fakes and real PPD fixtures.

## 1. Product constraints and the Mac App Store boundary

FlipStack must read PPDs, submit raw CUPS options (`page-set`, `number-up`, PPD keywords), retrieve job IDs, poll terminal job state, and cancel a specific job. The Mac App Store requires App Sandbox, which blocks that surface:

- `/etc/cups/ppd/<queue>.ppd` and `/Library/Printers/PPDs` are outside the sandbox; user-selected file access does not grant system paths.
- `/usr/bin/lp`, `/usr/bin/lpstat`, `/usr/bin/cancel`, and `ipptool` cannot be reliably launched with `Process`; CUPS socket access is restricted.
- `NSPrint`/PrintCore does not expose page-set, 2-up imposition, PPD keyword control, job IDs, and cancellation with the fidelity the two-pass flow needs.

A temporary-exception sandbox is not a viable product boundary. FlipStack ships outside the store as a Developer ID signed, hardened-runtime, notarized DMG (section 12). It is still signed and notarized, not an unsigned utility. Shipping outside the sandbox does not mean skipping input validation: PPD text, `lpstat` output, IPP attributes, SNMP responses, and PDFs are untrusted; commands use argument arrays, never a shell.

## 2. Module boundaries and dependency direction

| Target | Responsibility | Imports |
|---|---|---|
| `FlipStackCore` | Models, protocols, CUPS, PPD, status, booklet, orchestrator | Foundation, PDFKit, CoreGraphics, Compression |
| `FlipStack` | AppKit/SwiftUI shell, menu bar, panel, notifications, preferences, utility PDFs | AppKit, SwiftUI, Combine, PDFKit, UserNotifications, `FlipStackCore` |
| `FlipStackCoreTests` | Hardware-free tests and fixtures | XCTest, `FlipStackCore` |

Dependency is one-way: `FlipStack` -> `FlipStackCore`. Core never imports the app or SwiftUI/AppKit UI. `DuplexNotifying` is declared in Core and implemented by the app's `NotificationService`.

```
+------------------------------- FlipStack.app -------------------------------+
| FlipStackMain -> AppDelegate                                                |
|   |                  +-> NotificationService : DuplexNotifying              |
|   |                  +-> MenuBarController -> NSStatusItem + FlipPanel      |
|   |                  |      +-> NSHostingView<RootView>                     |
|   +-> AppModel : ObservableObject                                           |
|          |  printers, status, PPD, document, options, preferences, queue    |
|          +-> DuplexOrchestrator : ObservableObject                          |
|                 |  DuplexPhase, pass jobs, flip gate, retry/cancel          |
+-----------------|-----------------------------------------------------------+
                  | PrintSpooling + DuplexNotifying
                  v
+------------------------------- FlipStackCore -------------------------------+
| CUPSClient : PrintSpooling          PPDLoader : PPDProviding                |
| IPPStatusClient : PrinterStatusProviding   BookletImposer : BookletImposing |
| Models: Printer, PrintJob, PPDDocument, DuplexDocument, BookletPlan, ...    |
+-----------------------------------------------------------------------------+
```

`DuplexOrchestrator` depends only on `PrintSpooling` and `DuplexNotifying`; it receives a prepared `DuplexDocument` and `DuplexConfiguration` and knows nothing about PDFKit, PPDs, the menu bar, or preferences. During a flow the job-control chain is UI -> `DuplexOrchestrator` -> `PrintSpooling`; `PPDProviding`, `PrinterStatusProviding`, and `BookletImposing` are preparation/display dependencies of `AppModel` and never bypass the orchestrator for job control. `AppModel` depends on `PrintSpooling`, `PPDProviding`, `PrinterStatusProviding`, `BookletImposing`, `DuplexOrchestrator`, and `PreferencesStore`; it owns document selection, PPD options, booklet preparation, queue display, and user errors. `MenuBarController` owns the status item, panel, and presentation, not flow state. `NotificationService` depends only on `DuplexNotificationEvent` and `FlipPrompt`, calling back through closures wired in `AppDelegate`.

```
Package.swift
Sources/FlipStack/       AppMain, AppDelegate, AppModel, MenuBarController,
                        NotificationService, PreferencesStore, PrintUtilities,
                        DemoSupport, DesignSystem/, Views/
Sources/FlipStackCore/   Models/{Printer,Print,PPD,Duplex,Booklet}Models.swift,
                        Services/Protocols.swift,
                        CUPS/ (client, discovery), PPD/, Status/,
                        Duplex/, Imposition/, Compatibility/
Tests/FlipStackCoreTests/Fixtures/PPDs/
```

Protocol seams keep tests hardware-free:

| Protocol | Implementation | Consumer | Test double | Isolates |
|---|---|---|---|---|
| `PrintSpooling` | `CUPSClient` | orchestrator, `AppModel` | `MockPrintSpooler` | `lp`/`lpstat`/`cancel`, job states |
| `PPDProviding` | `PPDLoader` | `AppModel` | fixture provider | system PPD paths, gzip |
| `PrinterDiscovering` | `CUPSDeviceDiscovery` | `AppModel` | scripted discovery | `lpinfo -v`, USB/Wi-Fi candidates |
| `PrinterStatusProviding` | `IPPStatusClient` | `AppModel` | stub status | IPP, SNMP, network |
| `BookletImposing` | `BookletImposer` | `AppModel` | stub or real + PDF fixtures | PDFKit, temp files |
| `DuplexNotifying` | `NotificationService` | orchestrator | `MockDuplexNotifier` | UserNotifications |
| `PreferencesStoring` (app-internal) | `PreferencesStore` | `AppModel` | `UserDefaults(suiteName:)` | preferences pollution |

All service protocols are `Sendable`; `DuplexNotifying` is `@MainActor`. A state-machine test injects a scripted `MockPrintSpooler` and `MockDuplexNotifier` and asserts phase order, exact `PrintRequest` values, and notification events. No printer, CUPS daemon, or permission prompt.

## 3. Page order for a face-up simplex printer

Definitions: `S1` is the sheet whose front is page 1, `S2` front page 3, `S3` front page 5. The back of `S1` is page 2, and so on. "Top to bottom" is tray order. Face-up output means each ejected sheet lands printed side up, so the last sheet printed is on top. A whole-block flip over the long edge is a 180-degree rotation of the entire stack around its long (vertical) edge, like turning a book page; it turns the stack face-down and reverses sheet order, without reordering pages within a sheet.

Pass 1 uses the source PDF with `PageSet.odd` (`-o page-set=odd`); pass 2 uses `PageSet.even` (`-o page-set=even`). `PrintRequest` has no `outputOrder` field and the command builder must not add `-o output-order=reverse`. The contract sentence `DuplexCopy.noReversal` is:

> No page reversal is used. The physical flip puts the sheets back in the right order.

### Six pages

```
Pass 1 output (face-up):       top S3 [p5]  S2 [p3]  S1 [p1] bottom
Whole-block flip (long edge):  top S1 [p1 down, blank up]  S2 [p3 down]  S3 [p5 down] bottom
Pass 2 (page-set=even):        S1 -> p2, S2 -> p4, S3 -> p6
Pass 2 output (face-up):       top S3 [p6]  S2 [p4]  S1 [p2] bottom
Turn finished stack over:      S1 [p1], S2 [p3], S3 [p5]
```

Each sheet is correctly paired: `S1 = p1/p2`, `S2 = p3/p4`, `S3 = p5/p6`. Pass 1 output is reverse sheet order because each new sheet lands on top. The flip reverses the stack again, putting `S1` on top with its blank side up. Pass 2 feeds `S1` first, so p2 lands on the back of the sheet carrying p1.

### Five pages

`DuplexDocument.manualDuplex` computes `sheetCount = ceil(5/2) = 3`, `firstPass.pageCount = (5+1)/2 = 3`, `secondPass.pageCount = 5/2 = 2`, `hasOddPageCount = true`, `hasBlankFinalBack = true`.

```
Pass 1 output:       top S3 [p5]  S2 [p3]  S1 [p1] bottom
Flip long edge:      top S1 [p1 down, blank up]  S2 [p3 down]  S3 [p5 down] bottom
Pass 2 (even):       S1 -> p2, S2 -> p4, S3 -> no page (back blank)
Final:               top S3 [blank up]  S2 [p4]  S1 [p2] bottom
Turn the stack:      S1 [p1], S2 [p3], S3 [p5]
```

Odd-count caveat: a `page-set=even` job has only two impressions for five pages. The printer may not eject the third, unprinted sheet; it can remain in the input tray. If so, place it on top of the output stack, blank side up, before turning the stack. That reproduces the table. `FlipPrompt.footnote` states the content outcome: "The document has an odd page count, so the last sheet’s back stays blank." The UI must not promise every physical sheet is automatically ejected.

### Single-sided and page selections

`PrintMode.singleSided` is a first-class mode, not a simulation of a two-pass job. `AppModel.beginPrint` builds `DuplexDocument.singleSided`, whose first pass is `pageSet = .all` and whose second pass has zero pages. The orchestrator submits one `lp` request and completes without a flip prompt. It deliberately omits the `Duplex` driver option and sends `sides=one-sided`, so a queue that understands hardware duplex is not asked to turn a page. Copies (1–20) are passed through to `lp`; two-sided modes force one copy at a time because a single physical stack cannot be interleaved safely across copies.

For a queue whose PPD advertises hardware duplex, manual two-pass mode still runs the physical workflow, but `DuplexConfiguration.forceOneSidedPasses` makes each pass `sides=one-sided` instead of setting `Duplex`; otherwise a duplex-capable driver could turn pages inside a manual pass. Simplex queues such as the L1800 receive the required `Duplex=NoTumble`/`Tumble` intent.

A page range such as `1-4, 7` is normalised to ascending, unique, one-based page numbers and compiled into a temporary PDF by `PDFPageExtractor` before any mode-specific preparation. Manual duplex then treats the selection as a new document starting at sheet 1, so odds/evens pair correctly even when the range starts on an even source page. Booklet mode imposes the same selected page set. The selection PDF lives in a private temporary directory and is removed after completion or cancellation; it is retained after a failure so **Retry backs** can use it.

`PrintMode.singleSided` does not require the per-printer flip calibration. Duplex and booklet do. The UI keeps the mode switch disabled during a flow so the document being prepared cannot change underneath it.

### Why reversing breaks the backsides

The flipped stack feeds `S1`, then `S2`, then `S3`. Pairing is positional:

```
Pass 2 order   S1 first   S2 next   S3 last   result
2, 4, 6        p2         p4        p6        correct
6, 4, 2        p6         p4        p2        wrong
```

`-o page-set=even` preserves document order. `-o output-order=reverse` reverses it to 6, 4, 2; `S1` still feeds first, so it receives p6, `S2` receives p4, `S3` receives p2. Every backside shifts. Software reversal is only correct for a different physical stack orientation, not the FlipStack face-up path. The physical flip is the only operation that reverses sheet order.

The flip prompt is deliberately restrictive:

> Flip the WHOLE stack over as one block — do NOT reorder or reverse the pages — reinsert it, then press Continue.

### Face-down path and axis

`PrinterPreferences.ejectsFaceDown` selects `FlipMode.reinsertOnly`; `false` selects `FlipMode.flipBlock`. For a queue whose face-down path collates this way, the stack arrives printed side down with sheet 1 on top and blank sides up; reinsert exactly as it is, no flip, no reversal. `FlipPrompt.make` uses `DuplexCopy.reinsertMessage`:

> Reinsert the stack exactly as it is — do NOT reorder or reverse the pages — then press Continue.

with detail "Your output tray ejects face-down, so the stack is already in the right order." `PrinterPreferences.flipMode` and `DuplexConfiguration.flipMode` compute from the same boolean, so copy and state cannot disagree. The toggle encodes observed queue behavior, not a universal law; `hasConfiguredFlip` gates the first-run calibration.

`FlipAxis.longEdge` ("Book", turn like a book page) maps to `Duplex=NoTumble`; `.shortEdge` ("Calendar") maps to `Duplex=Tumble`. `FlipAxis.cupsDuplexValue` is the single mapping, and `DuplexConfiguration.driverOptionsWithDuplex` adds it to both passes. The axis is persisted per printer and records intent even when a simplex driver ignores `Duplex`. FlipStack targets simplex queues; on a hardware-duplex queue the option may be honored, which is outside the v1 contract.

## 4. Duplex state machine

`DuplexPhase` is the entire public flow state:

| Phase | Meaning | Active job |
|---|---|---|
| `.idle` | No flow; setup or ready | none |
| `.preparing` | Validate document/configuration, resolve files, preflight queue | none |
| `.printing(pass: .fronts, job:)` | First pass submitted and monitored | fronts |
| `.awaitingFlip(FlipPrompt)` | Fronts terminal; waiting for the human | none |
| `.printing(pass: .backs, job:)` | Second pass submitted and monitored | backs |
| `.completed(DuplexResult)` | Both passes (or the only pass) completed | none |
| `.failed(DuplexFailure)` | Terminal flow error | none |
| `.cancelled(DuplexPass?)` | User cancelled; pass when known | none |

`DuplexPhase.isActive` is true for `.preparing`, `.printing`, and `.awaitingFlip`; `AppModel.canPrint`, printer selection, document clearing, and reset guard on it. Public methods are `start(document:configuration:)` (returns `Task<Void, Never>`), `confirmFlip()`, `cancel()`, `retryBacks()`, and `reset()`.

| From | Event | Guard | Effect | Notification |
|---|---|---|---|---|
| idle | `start` | pages > 0; queue exists; no active phase | `.preparing`; create run task | none |
| preparing | validation succeeds | first-pass file exists; printer accepts jobs | submit `firstPass`; `.printing(fronts, job)` | none |
| preparing | validation fails | — | `.failed(.invalidDocument/.printerUnavailable)` | `.failed` |
| printing(fronts) | job active | pending/held/processing | update job; reset progress clock on change | none |
| printing(fronts) | job completes | `document.hasBackSides` | build `FlipPrompt.make(...)`; `.awaitingFlip` | `.flipRequired` |
| printing(fronts) | job completes; printer stopped | error persists past grace | `.failed(.printerStopped(.backs, reasons))` | `.failed` |
| printing(fronts) | job completes | `secondPass.pageCount == 0` | build `DuplexResult`; `.completed` | `.completed` |
| printing(fronts) | failure/stuck/monitor loss | — | `.failed(...)` | `.failed` |
| awaitingFlip | `confirmFlip` | phase is `.awaitingFlip` | resume gate once; submit `secondPass`; `.printing(backs, job)` | none |
| awaitingFlip | `cancel` | phase is `.awaitingFlip` | resume gate with cancel; `.cancelled(.fronts)` | `.canceled` |
| printing(backs) | job completes | — | build `DuplexResult`; `.completed` | `.completed` |
| printing(backs) | failure/stuck/monitor loss | — | `.failed(...)`; `canRetryBacks == true` | `.failed` |
| failed | `retryBacks` | `failure.canRetryBacks` | `.preparing`; submit only `secondPass`; no new fronts | none |
| failed/cancelled/completed | `reset` | no active phase | `.idle`; clear result/failure | none |
| any active | `cancel` | job exists | `spooler.cancel`; `.cancelled(activePass)` | `.canceled` |
| prepare / awaitingFlip confirm / backs | printer stopped with errors | persists past `printerErrorGracePeriod` | `.failed(.printerStopped(pass:reasons:))` | `.failed` |

`DuplexResult` is built once at completion: printer name, source page count, physical sheet count, `isBooklet`, `hadBlankFinalBack`, elapsed time. `AppModel.track` awaits the run task, refreshes queue/status, and cleans booklet temporary files on `.completed` or `.cancelled`.

### Monitoring: real state, never a fixed timer

After `PrintSpooling.submit(_:)` returns a `PrintJob` with a CUPS job ID, the orchestrator polls `PrintSpooling.job(id:printerID:)` every `DuplexConfiguration.pollInterval` (default 0.75 s). Completion is always a terminal CUPS/IPP job state, never "queue looks empty" and never a sleep proportional to page count.

| IPP job-state | `JobState` | Handling |
|---|---|---|
| 3 / 4 / 5 | `.pending` / `.held` / `.processing` | active; keep polling |
| 6 | `.stopped` | failure candidate; allow printer-error grace, then fail |
| 7 / 8 / 9 | `.canceled` / `.aborted` / `.completed` | terminal failure / failure / success |
| other/missing | `.unknown` | active until timeout or a definite state |

`JobState.isTerminal` excludes `.stopped`; `isFailure` includes it. The orchestrator handles `.stopped` explicitly rather than waiting for a terminal state that may never arrive. `.held` and `.unknown` are bounded by the stuck timeout.

Rules:

- **Progress clock.** Track last `(state, impressionsCompleted, stateReasons)`; any change resets a monotonic deadline. No change for `jobStuckTimeout` (default 240 s) while active or stopped-with-grace -> `.jobStuck(pass:seconds:)`.
- **Job disappears.** `job(id:)` returns `nil` when CUPS no longer knows the job. If no terminal state was observed, this is `.monitorFailed(pass:message:)`, not success.
- **Spooler errors.** A thrown `CUPSCommandError` is retried a small bounded number of times; persistent failure is `.monitorFailed`. `.timedOut` is not proof the job failed.
- **Printer error between passes.** After fronts completes, and again before submitting backs, query `spooler.printer(id:)`. Run the first check before publishing `.awaitingFlip`; a persistently stopped printer fails instead of asking for a flip. If `state == .stopped` or `hasError`, poll up to `printerErrorGracePeriod` (default 8 s). Transient reasons such as `connecting-to-device` may clear; persistent errors fail with `.printerStopped(pass: .backs, reasons:)`.
- **No overlapping monitors.** One poll loop per active job; `cancel()` and the flip gate must not race the loop into submitting the next pass twice.

### Odd page count, one page, cancellation

`DuplexDocument.manualDuplex` is the pass shape:

| Pages | Sheets | Fronts | Backs | Flip? | Blank final back |
|---|---|---|---|---|---|
| 1 | 1 | 1 (p1) | 0 | no | yes |
| 2 | 1 | 1 (p1) | 1 (p2) | yes | no |
| 5 | 3 | 3 (p1,p3,p5) | 2 (p2,p4) | yes | yes |
| 6 | 3 | 3 (p1,p3,p5) | 3 (p2,p4,p6) | yes | no |

For one page, `secondPass.pageCount == 0`, `hasBackSides == false`; the flow goes straight to `.completed` and posts no flip notification. For a booklet, `AppModel.makeBookletDocument` sets `hasOddPageCount: false` because the plan pads with blanks; booklets always have backs.

Cancellation: during fronts, call `spooler.cancel`, `.cancelled(.fronts)`, no backs. During `.awaitingFlip`, no job exists; resume the gate with cancellation, `.cancelled(.fronts)`. During backs, cancel the backs job, `.cancelled(.backs)`; fronts remain, partial backs may leave mixed sheets. `cancel()` is idempotent; `confirmFlip()` outside `.awaitingFlip` is ignored; `reset()` while active is rejected. `DuplexFailure.cancelled(pass:)` exists for failure-shaped paths, but the normal user cancel surface is `DuplexPhase.cancelled`; do not post both.

### The physical flip gate

`.awaitingFlip` sits exactly between fronts reaching `.completed` and backs being submitted. The orchestrator builds `FlipPrompt.make(printerName:sheetCount:flipAxis:mode:hasOddPageCount:)`, publishes the phase, and calls `DuplexNotifying.handle(.flipRequired(prompt))`. The run task suspends on a continuation; `confirmFlip()` resumes it once and submits backs; `cancel()` resumes it with cancellation.

The gate cannot be automated. A simplex printer has no sensor for "the stack was removed, turned over, and reinserted." The queue only knows fronts finished. A timer would print backs onto whatever is in the tray. The user's Continue click, or the notification's Continue action, asserts the physical precondition. The app makes that assertion unambiguous: one prompt, the exact flip sentence, axis, sheet count, and odd-page footnote.

## 5. PPD-driven options

`PPDProviding.locatePPD(for:)` resolves in this order:

```
1. /etc/cups/ppd/<queue>.ppd[.gz]        authoritative queue PPD
   Printer.ppdPath                       only a hint to that same queue PPD
2. /Library/Printers/PPDs/**/*.ppd[.gz]  vendor PPD fallback
```

The queue PPD is first because it is the file CUPS uses for that queue. A vendor PPD is a fallback for read-only capability discovery, not a driver install; if it does not match the queue's model strongly, return `nil` rather than expose wrong options. Matching normalizes `Printer.model`/`modelName` and each candidate's `NickName`, `Manufacturer`, and `ModelName`; require manufacturer-plus-model tokens (not "Epson" alone), prefer an exact normalized nickname, then a unique shortest model match, and return `nil` if ambiguous. Decompress `.gz` with a size cap; record the chosen file in `PPDDocument.sourcePath`. Driverless IPP Everywhere queues often have no PPD; that is the no-PPD case, not an error.

Parsing is line-oriented over the UI subset:

```
*OpenUI *ColorModel/Color Model: PickOne
*ColorModel RGB/RGB Color: "<...>"
*ColorModel Gray/Grayscale: "<...>"
*DefaultColorModel: RGB
*CloseUI: *ColorModel
```

- `*OpenUI` starts an option (keyword before `/`, label after); `*Keyword ChoiceLabel/Choice: "raw"` adds a `PPDChoice`; `*DefaultKeyword: Choice` sets `PPDOption.defaultChoice`; `*CloseUI` ends it. `PPDChoice.keyword` is the command-line value; `PPDChoice.value` preserves the raw PPD value for diagnostics. CUPS driver options are sent as `-o Keyword=ChoiceKeyword`, not as the PostScript dictionary. Missing/invalid defaults fall back to `PPDOption.selectedDefault` (first choice).
- `PPDOptionGroup` assigns keywords via `PPDOptionGroup.preferredKeywords`: color (`ColorModel`, `ColorMode`, `cupsColorModel`), paper size (`PageSize`, `MediaSize`, `PageRegion`), media (`MediaType`, `InputSlot`), quality (`Resolution`, `PrintQuality`, `RasterQuality`, `cupsPrintQuality`), duplex (`Duplex`). `PPDDocument.option(in:)` falls back to any option already assigned to the group.
- `PPDDocument.supportsHardwareDuplex` is true when a `Duplex` option has a non-`None` choice; it is capability information, not a flow switch. `isPseudoOption` marks CUPS pseudo-options such as `cupsColorModel` and `cupsPrintQuality`.

`AppModel.driverOptions` exposes only color, paper size, media type, and quality, in that order. It does not expose a free `Duplex` picker; `FlipAxis` owns that value. `AppModel.currentDriverOptions` serializes selected choice keywords and drops values that are not real choices. `DuplexConfiguration.driverOptionsWithDuplex` then adds `Duplex = flipAxis.cupsDuplexValue` on both passes. Reserved CUPS options (`page-set`, `number-up`, `orientation-requested`, `output-order`) are owned by the command builder and are never accepted from PPD selections.

**No-PPD rule.** If discovery returns `nil`, parsing throws, or `PPDDocument.isEmpty` is true: `AppModel.ppd` is `nil`, `driverOptions == []`, `currentDriverOptions == [:]`, and `ppdNote` is one of "No driver PPD was found for this queue. Only the system defaults will be used." or "The driver description could not be read. Only the system defaults will be used." The UI hides/disables driver controls; it never shows "Color: RGB", "Paper: A4", "Media: Plain", or a resolution not parsed from a PPD. Printing still works because `PrintRequest` always carries standard CUPS fields and `driverOptions` may be empty. Fabricating options is worse than none: a queue may reject the job or silently substitute paper/color.

### Quality presets, layout, profiles, and photo printing

`PrintPresetResolver` maps `PrintQualityPreset` (Eco, Standard, High, Photo) onto the real choices in a `PPDDocument`; it never invents a keyword or value. It ranks numeric resolutions and semantic quality/media/color labels, preserves unrelated base options, and marks a preset incomplete when its quality or media groups cannot be resolved. The Photo preset additionally chooses a photo ICC/profile option when the PPD exposes one. `AppModel` persists the resulting per-printer PPD choice dictionary and exposes the active preset; manual driver edits switch the display to Custom. If the PPD is unavailable, presets are not offered and the system defaults are used.

Layout controls are standard CUPS attributes rather than fabricated PPD options: automatic orientation (no option), forced landscape (`orientation-requested=4`), and fit-to-page (`fit-to-page=true`). Layout is applied to both passes of a manual duplex job and is disabled for booklet imposition, which supplies its own 2-up layout. Layout choices are stored per printer under `"FlipStack.printLayout.v1"`.

Color profiles are the PPD's own profile options (keywords/labels containing `profile` or `ICC`), exposed in a compact menu and passed through `lp -o Keyword=Choice`. The Photo preset resolves them automatically. Do not claim a print-time ICC transform when the driver exposes no profile choices; input-profile conversion is outside v1.

`PrinterDiscovering`/`CUPSDeviceDiscovery` runs `/usr/sbin/lpinfo -v` without a shell to discover USB, Bonjour, IPP/IPPS, socket, and LPD candidates. Discovery candidates are not print destinations: `AppModel` subtracts devices that already match a configured queue and the UI links unconfigured candidates to Printers & Scanners. Discovery runs asynchronously at launch and on demand, with a long enough bounded timeout for the CUPS backends, and never blocks queue loading or printing.

## 6. Booklet imposition

`BookletPlan` describes saddle-stitch imposition: `sourcePageCount`, `paddedPageCount`, `signatureSheetCount` (`k`), `signatureCount`, `spreads` (one `BookletSpread` per physical sheet, each with `front`/`back` `BookletPagePair`), `signatures` (`BookletSignature(index:firstPage:lastPage:sheetCount:)`), and flattened `frontPageSequence`/`backPageSequence` where `nil` is blank. `sheetCount == spreads.count`; `paddedSheetCount == paddedPageCount / 4`.

For a signature with first page `first`, `k` sheets, `last = first + 4k - 1`, sheet `i` (1-based):

```
frontLeft(i)  = last  - 2(i - 1)
frontRight(i) = first + 2(i - 1)
backLeft(i)   = first + 1 + 2(i - 1)
backRight(i)  = last  - 1 - 2(i - 1)

frontPageSequence = [frontLeft(1), frontRight(1), frontLeft(2), frontRight(2), ...]
backPageSequence  = [backLeft(1),  backRight(1),  backLeft(2),  backRight(2),  ...]
```

`signatureCount = ceil(paddedPageCount / (4k))`; the last signature keeps its remaining full sheets and is not padded out to `4k` (each signature is always a multiple of 4 pages). `paddedPageCount = ceil(pageCount / 4) * 4`. `k >= 1`; when `signatureSheets == nil`, the auto policy uses one signature for six or fewer padded sheets, otherwise four sheets per signature with a 1–4-sheet final signature. Tests pin that policy.

**Eight pages, `k = 2`, one signature:**

| Sheet | Front (left, right) | Back (left, right) |
|---|---|---|
| 1 | 8, 1 | 2, 7 |
| 2 | 6, 3 | 4, 5 |

`fronts PDF pages: [8,1] [6,3]`; `backs PDF pages: [2,7] [4,5]`. `sheetCount == 2`, `paddedPageCount == 8`, `hasBlankPages == false`. `foldHint` is "Fold the stack in half with the printed pages facing out."; `stapleHint` is "Staple twice along the fold after folding."

**Twelve pages, two signatures (`signatureSheets: 2`):** signature 1 is pages 1–8 (two sheets), signature 2 is pages 9–12 (one sheet).

| Signature / sheet | Front | Back |
|---|---|---|
| S1, sheet 1 | 8, 1 | 2, 7 |
| S1, sheet 2 | 6, 3 | 4, 5 |
| S2, sheet 1 | 12, 9 | 10, 11 |

```
frontPageSequence = [8, 1, 6, 3, 12, 9]
backPageSequence  = [2, 7, 4, 5, 10, 11]
```

`sheetCount == 3`, `paddedPageCount == 12`, `paddedSheetCount == 3`, `signatureCount == 2`, `hasBlankPages == false`. `foldHint` is "Fold each of the 2 signatures separately, then nest them in order."; `stapleHint` is "Staple each signature twice on the fold, then stack the signatures in order." For contrast, auto `k = 3` would make one 12-page signature with no blanks: fronts `[12,1,10,3,8,5]`, backs `[2,11,4,9,6,7]`.

**Why separate PDFs and `number-up=2`.** The imposed PDFs contain individual source pages in the flattened sequences above: `frontsURL` and `backsURL` each have `2 * sheetCount` pages. They print with `PrintSource.numberUp = 2`, `pageSet = .all`, and no `page-set` option. `number-up=2` groups each adjacent pair into one physical sheet side; `PrintSource.pageCount` is `plan.sheetCount`. Separate files are required because (1) front and back orders differ; a single PDF with `page-set=odd/even` would select individual PDF pages, and with `number-up=2` could split a pair; (2) each pass must contain exactly the sides it prints, so 2-up is a simple adjacent-pair grouping with no page-selection interaction; (3) the backs PDF can be regenerated or retried independently, and both clean up via `BookletDocuments.workingDirectory`/`BookletImposing.cleanUp`. Standard duplex, by contrast, uses one PDF, `numberUp = 1`, and `page-set=odd/even`. Neither path uses `output-order=reverse`.

**Why booklet forces long-edge.** `AppModel.beginPrint` builds the booklet configuration with `flipAxis: .longEdge` regardless of the saved axis. The imposition assumes backs are the long-edge mirror of fronts: the folded spine runs along the long edge of the portrait pages, and each back pair must align when folded. A short-edge flip rotates every back 180 degrees, so the halves of a spread do not meet at the fold. Booklets send `Duplex=NoTumble` and use the book-style flip; `ejectsFaceDown` still decides whether the action is a flip or reinsert. `AppModel.makeBookletDocument` sets `hasOddPageCount: false`; the plan pads with blanks, so there is always a backs pass. `BookletPlan.foldHint`/`stapleHint` are shown after completion. Creep compensation, gutter adjustment, crop marks, cover pages, and perfect binding are out of scope.

## 7. Status pipeline

`IPPStatusClient` implements `PrinterStatusProviding.status(for:) async -> PrinterStatus` and never throws. It prefers the local CUPS queue so status matches `lp`/`lpstat`: IPP `Get-Printer-Attributes` to `ipp://localhost:631/printers/<queue>`, requesting `printer-state`, `printer-state-reasons`, `printer-state-message`, `printer-is-accepting-jobs`, `queued-job-count`, `printer-marker-supplies` (and standard `printer-supply`/`printer-supply-description` where available). `requested-attributes` is encoded as one IPP `1setOf` attribute with multiple keyword values; repeating the attribute name makes CUPS return only the first requested value.

| Attribute | Mapping |
|---|---|
| `printer-state` 3 / 4 / 5 | `PrinterState.idle` "Ready" / `.processing` "Printing" / `.stopped` "Stopped" |
| missing/unknown | `.unknown` "Unknown"; never render as Ready |
| `offline-report` while idle | `PrinterHealth.offline` "Offline" with a wake-on-print note, not Ready |
| no marker supplies | a designed "supply levels are not reported" fallback, not a fake 0% |
| `printer-state-reasons` | raw strings in `stateReasons`; `PrinterReason.humanReadable` for labels |
| `printer-is-accepting-jobs` | `PrinterStatus.acceptsJobs`, merged into `Printer.acceptsJobs` by `AppModel.refreshStatus` |
| `queued-job-count` / `printer-state-message` | `PrinterStatus.queuedJobCount` / `.stateMessage` |
| marker supplies | `[SupplyLevel]` with kind, color, optional percent, estimate flag |
| success / failure | `StatusOrigin.ipp` / fall through to SNMP, lpstat, or `.unavailable` |

Supply percentages are normalized only when level and capacity are meaningful; `SupplyLevel.levelPercent` is `nil` when unknown and must not render as 0%. The header renders every reported marker in an adaptive grid, including light cyan/light magenta/photo black/waste, and shows a designed unavailable-supplies message when a USB queue exposes no markers. `isLow` is at most 12%, `isCritical` at most 4%. `StatusOrigin.lpstat` is queue-only and cannot supply live marker levels. `.unavailable` uses `PrinterStatus.unknown(for:)`, preserving the last known state and adding "Live status is not available right now."

**SNMP fallback.** If IPP fails and the queue has a network URI, query SNMPv2c read-only: 2 s timeout, one retry, no SET. USB-only queues stay `.unavailable`.

| MIB | OID | Use |
|---|---|---|
| `hrPrinterStatus` | `1.3.6.1.2.1.25.3.5.1.1` | coarse state |
| `hrDeviceStatus` | `1.3.6.1.2.1.25.3.2.1.5` | running/warning/down |
| `hrPrinterDetectedErrorState` | `1.3.6.1.2.1.25.3.5.1.2` | error bits |
| `prtMarkerSuppliesDescription` | `1.3.6.1.2.1.43.11.1.1.6` | supply name |
| `prtMarkerSuppliesType` | `1.3.6.1.2.1.43.11.1.1.5` | supply kind |
| `prtMarkerSuppliesMaxCapacity` | `1.3.6.1.2.1.43.11.1.1.8` | denominator |
| `prtMarkerSuppliesLevel` | `1.3.6.1.2.1.43.11.1.1.9` | current level |
| `prtMarkerColorantValue` | `1.3.6.1.2.1.43.12.1.1.4` | color name |
| `prtAlertSeverityLevel` | `1.3.6.1.2.1.43.18.1.1.4` | alert severity |
| `prtAlertDescription` | `1.3.6.1.2.1.43.18.1.1.8` | alert text |

`hrPrinterStatus` 3/4 -> idle/processing; `hrDeviceStatus` down -> stopped when state is ambiguous. Alerts and error bits become state reasons where a stable keyword exists, or human-readable text otherwise. SNMP success sets `.snmp`; partial success keeps known state and leaves unknown supplies empty.

UI badges read the model, not raw protocol values: `PrinterHealth` (Ready/Preparing/Printing/Your turn/Offline/Needs attention/Unknown), `PrinterState.label`, `Printer.hasError`, `PrinterStatus.actionableReasons` (labels such as "Out of paper", "Paper jam", "Ink empty", "Cover open", "Printer offline"), `Printer.isOffline`, `SupplyLevel.displayName`/`.isLow`/`.isCritical` (unknown omitted), `StatusOrigin` (IPP live, SNMP fallback, lpstat queue-only, unavailable), and `PrinterStatus.note`.

Cadence: idle status + queue every 20 s (`AppModel.startMonitoring`); immediate refresh when the popover opens; job state every 0.75 s while a FlipStack job is active; status at pass boundaries; printer-error polling every 0.75 s up to 8 s. The queue refreshes every 3 s while its drawer is open. The 20 s monitor is UI freshness, not job completion. Status and queue refreshes are single-flight for the selected queue; there is no exponential backoff or per-printer status cache yet, so a slow or unreachable queue can occupy one refresh cycle. SNMP is attempted for a network queue when IPP succeeds without marker supplies or when IPP fails.

## 7.1 Automatic flip calibration

First-time setup is a guided calibration rather than a guess. `AppModel.startFlipCalibration` generates a generic one-page orientation sheet with no document content, submits it with `sides=one-sided`, and monitors the real CUPS job through `spooler.job(id:printerID:)`. Completion is accepted only from `.completed`; cancellation, abort, stopped state, three consecutive lookup errors, or a 10-minute safety deadline produce a designed failure surface. The deadline cancels the calibration job and is not used as a completion signal.

The sheet is printed before the document is exposed to the orchestrator. The selected PDF remains in the composer and is started only after the user applies the calibration, so a failed or cancelled sheet cannot consume document paper. The sheet carries orientation markers so the user can identify the printed side. The user must explicitly confirm both answers:

| Question | Stored value |
|---|---|
| When it landed, which side was up? | `ejectsFaceDown`: blank side up means the printed side landed face-down |
| Turn direction | `FlipAxis`: `.longEdge` for portrait/book-style documents; `.shortEdge` for landscape/calendar-style documents |

The turn is recommended from the current selected document's first-page orientation and the per-printer layout setting (booklets always use the long edge), but it is not saved until the user confirms it. No answer is preselected after the sheet completes. The sticky action bar stays disabled until both answers are confirmed. The result is stored in `PrinterPreferences` and `AppModel.calibrationSummary` is shown in the confirmation. A standalone **Flip orientation sheet** action prints the same generic sheet without entering the question flow, for re-checking a queue after a tray change. Calibration can be re-run from the flip setup surface or the maintenance menu.

The calibration sheet intentionally contains no printer name, document title, date, serial number, or path. Only its generic title and orientation markers are printed. Temp files use the existing per-user `FlipStack` temp directory and are removed after submission; the state machine is in `AppModel` and the surface is `Views/FlipCalibrationView.swift`.

## 7.2 Privacy boundary

The app has no telemetry, analytics, accounts, remote logging, or third-party SDK. Network activity is limited to CUPS/IPP for the selected queue, CUPS `lpinfo` discovery (which may generate LAN/mDNS traffic), optional read-only SNMP to a configured network printer, and—only when `CUPS_SERVER` explicitly points at one—a remote CUPS status endpoint. No document content is included in status or discovery traffic. CUPS jobs use generic titles; the queue panel displays only jobs owned by the current macOS/CUPS user or submitted by this session. CUPS itself retains history independently. Document processing is local; temporary directories are created with user-only permissions and removed on launch and normal termination. Calibration sheets and notification banners intentionally contain no document, queue-owner, serial-number, or file-path data. See [PRIVACY.md](../PRIVACY.md).

## 8. UI architecture

### Panel and status item

`MenuBarController` owns `NSStatusItem.squareLength` (programmatic template icon `makeIcon(waiting:)`, accessibility label "FlipStack print manager", right-click Open/Quit), and `FlipPanel`: an `NSPanel` subclass with `canBecomeKey == true`, `canBecomeMain == false`, borderless, nonactivating, full-size content, `.popUpMenu` level, floating, not released when closed, no panel shadow. Its container has a layer shadow; an `NSVisualEffectView` (material `.popover`, behind-window, active, 20 pt corner radius, separator border) hosts exactly one `NSHostingView<RootView>`, pinned to its bounds. Presentation: 388 pt wide by up to 680 pt tall, capped to the space between the menu bar and the Dock and centered under the status item, 6 pt below. The SwiftUI tree is a scrollable column with sticky primary action and footer, so shorter displays remain usable. Global mouse-down, local outside click, Esc, and app resign close it; monitors are removed on close. Presentation uses a 0.965 -> 1.0 spring and 0.14 s fade, skipped when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true. `$phase` updates the icon/tooltip and presents on `.awaitingFlip`. One hosting view means the SwiftUI tree is created once and survives hide/show; it is not rebuilt.

### Print preview and capability controls

The idle composer includes an inline `DocumentPreviewPanel` rather than a separate window or sheet. For single-sided and duplex jobs it previews the selected-page PDF in print order; for booklets `BookletImposer` generates the fronts/backs PDFs and the panel pairs adjacent PDF pages into the actual 2-up sheet sides, with a Fronts/Backs switch and page navigation. Preview files live under a dedicated temporary directory, are discarded when the document, mode, page range, or signature size changes, and are removed before printing. The primary action bar is hidden while the preview is open so the preview and its navigation fit on smaller panels.

Quality presets, color-mode/profile menus, page range, orientation, fit-to-page, copies, and the six PPD option groups share the same `AppModel` state that the orchestrator serializes into `PrintRequest`. A preset edit rewrites only real PPD choices; a raw driver edit moves the preset indicator to Custom. Per-printer option choices, layout, flip axis, and face-down behavior are persisted in UserDefaults.

### Ownership

| Concern | Owner |
|---|---|
| Printers, selection, PPD, driver options, document, booklet plan | `AppModel` |
| Preferences, onboarding, queue, queue errors, maintenance, banners | `AppModel` + `PreferencesStore` |
| `DuplexPhase`, active job, flip gate, retries, cancellation | `DuplexOrchestrator` |
| Status item, panel, presentation, icon, event monitors | `MenuBarController` |
| Notification permission, category, actions | `NotificationService` |
| Test/alignment PDFs | `PrintUtilities` |

`AppModel` never mirrors `phase` into a second `isPrinting` flag; it calls `start`, `confirmFlip`, `cancel`, `retryBacks`, `reset`, and reads `phase` for `canPrint`/guards. `RootView` observes both objects. This avoids split-brain states where the UI says "printing" while the state machine awaits a flip.

### State surfaces

State-as-design:

| Phase | Primary surface |
|---|---|
| `.idle`, no printer | Onboarding/setup |
| `.idle`, printer | Document picker, inline preview, Single/Duplex/Booklet mode, pages, layout, quality presets, profile, options, copies, Print |
| `.preparing` / `isPreparingPrint` | Page-range extraction and booklet imposition progress |
| `.printing(.fronts)` | "Fronts", `PrintJob.progress`, sheet count, Cancel |
| `.awaitingFlip(prompt)` | Flip surface: `prompt.title`, `message`, `detail`, `footnote`, printer, sheet count, axis glyph; Continue -> `confirmFlip`, Cancel -> `cancelFlow` |
| `.printing(.backs)` | "Backs", progress, Cancel |
| `.completed(result)` | Sheet count, blank-final-back note, booklet fold/staple hints, Done, "turn the stack as a block to read from page 1" |
| `.failed(failure)` | `failure.title`, `message`, `recoverySuggestion`; Retry backs when `canRetryBacks`; Start over; Open queue |
| `.cancelled(pass)` | "Printing canceled"; nothing else prints; Start over |

`flipAxisSetup` is a first-run inline surface: `requestPrint` opens it when `hasConfiguredFlip` is false with `autoStartsPrint: true`; `completeFlipAxisSetup` saves and starts; `setEjectsFaceDown` also marks configured. Single-sided mode skips this surface.

### Animation

Signature animation: a stack of rounded rectangles, one per visible sheet, capped with the true count in text. Long edge rotates 3D about the vertical axis with perspective; short edge about the horizontal; reinsert-only lifts and reinserts without a flip. It is a whole-block motion, not a page shuffle. The stack is decorative and `accessibilityHidden`; an adjacent label says "Stack of N sheets. Flip the whole stack over its long edge. Do not reorder."

### Accessibility

Accessibility: Reduce Motion skips spring/3D and uses a static before/after arrow plus text (SwiftUI should also use `@Environment(\.accessibilityReduceMotion)`); VoiceOver announces phase changes, gives the status item label/help, labels Continue/Cancel explicitly, and reads the flip sentence intact; Dynamic Type uses semantic styles, wraps the long message, and scrolls the fixed 388x680 panel; contrast works in light/dark, and state is never color-only; Esc closes, Return activates the default, and the panel is key so buttons focus.

### Notifications

Notification handoff: `NotificationService` registers category `FLIPSTACK_FLIP` with `FLIPSTACK_CONTINUE` ("Continue", foreground) and `FLIPSTACK_CANCEL` ("Cancel", destructive), `.customDismissAction`. On `.flipRequired(prompt)` it calls `onOpen` first, then requests authorization lazily, then posts title `prompt.title`, subtitle "N sheets · FlipStack", and body `prompt.message` (`DuplexCopy.flipMessage` or `DuplexCopy.reinsertMessage`, exactly). Notification banners deliberately omit the printer name, document name, queue owner, and local paths. `.completed` removes the flip notification and posts "Printing complete"; `.failed` removes it and posts `failure.title` with a generic "Open FlipStack for details." body; `.canceled` removes it. Continue calls `onOpen` then `onContinue` (`AppModel.confirmFlip`); Cancel calls `onOpen` then `onCancel` (`AppModel.cancelFlow`); default click only opens. Fallback: `UNUserNotificationCenter.current()` is used only when `Bundle.main.bundleIdentifier != nil`; SwiftPM debug runs, denied permission, or a missing center still get the popover because `onOpen` runs before posting. `MenuBarController` also presents directly on `.awaitingFlip` and when calibration questions are ready, so notification permission is never required for the primary surface.

Notifications are convenience, not durable state. If the app quits during `.awaitingFlip`, the flow and continuation are gone; a post-relaunch action cannot resume it. `applicationWillTerminate` cancels; the user starts over. Do not imply a notification survives a quit.

## 9. Concurrency model

`AppModel`, `DuplexOrchestrator`, `MenuBarController`, `AppDelegate`, `NotificationService`, and `DuplexNotifying` are `@MainActor`; all `DuplexPhase` mutations and UI reads happen on main. `@Published var phase` drives Combine; `MenuBarController` uses `.receive(on: RunLoop.main)` defensively. Core value types (`Printer`, `PrintJob`, `PrintRequest`, `PPDDocument`, `DuplexDocument`, `DuplexConfiguration`, `DuplexResult`, `BookletPlan`, `FlipPrompt`) are `Sendable`; service protocols are `Sendable` and must not touch UI or main-actor state.

`CUPSClient` runs `Process` off main via an actor or private serial queue, builds argument arrays, sets `LC_ALL=C`/`LANG=C`, reads stdout/stderr pipes to EOF (avoiding pipe deadlock), enforces a timeout, and maps termination to `CUPSCommandError`. It never interpolates text into a shell. `PPDLoader` and `BookletImposer` do file/PDF work off main; `AppModel` uses `Task.detached(priority: .userInitiated)` with `Sendable` captures, then hops back to publish. `IPPStatusClient` uses async URLSession/IPP and SNMP off main and never throws across the protocol boundary. `PreferencesStore` is main-actor only; `UserDefaults` is thread-safe but `PreferencesStoring` is not `Sendable`, so it is not passed to detached tasks.

Awaiting-flip continuation rules:

1. The run task suspends on one checked continuation (or equivalent single-consumer stream) after publishing `.awaitingFlip`.
2. `confirmFlip()` checks `.awaitingFlip`, clears the continuation, then resumes with "continue"; the run task submits backs.
3. `cancel()` checks `.awaitingFlip`, clears the continuation, resumes with "cancel", and sets `.cancelled(.fronts)`.
4. Exactly one path wins; clearing before resuming makes a second call a no-op. Never resume from `deinit`; never store the continuation in a detached task that can outlive the orchestrator.
5. External task cancellation must resume the continuation with cancellation so the task cannot hang; the phase still transitions to `.cancelled` on main.
6. No `Task.sleep` flip wait, no busy loop. The gate is event-driven.

During monitoring, `cancel()` sends the CUPS cancel and transitions the phase; the poll loop observes the phase/cancellation flag and exits. Do not cancel the same job twice. On termination, `orchestrator.cancel()` is best-effort and non-blocking. `Task.detached` is only for CPU/IO with `Sendable` captures; `Task { }` in the app inherits main. `@unchecked Sendable` is not used for mutable state; a process runner or cache that needs it must be lock- or actor-protected and documented.

## 10. Error taxonomy and recovery matrix

| Layer | Type | Examples |
|---|---|---|
| Document | `DuplexDocumentError` | `.emptyDocument`, `.unreadableDocument`, `.invalidPageCount` |
| Booklet | `BookletError` | `.emptyDocument`, `.unreadableDocument`, `.cannotCreateWorkingDirectory`, `.cannotWrite`, `.invalidSignatureSheetCount` |
| Flow | `DuplexFailure` | `.invalidDocument`, `.printerUnavailable`, `.printerStopped`, `.submitFailed`, `.jobFailed`, `.jobStuck`, `.monitorFailed`, `.cancelled` |
| Process | `CUPSCommandError` | `.toolNotFound`, `.commandFailed`, `.invalidOutput`, `.printerNotFound`, `.jobNotFound`, `.fileNotFound`, `.timedOut` |
| Status | `PrinterStatus` | never throws; `.unavailable` + `note` |
| UI/queue | `AppModel.queueError`, `AppBanner` | queue refresh/cancel failures |

`DuplexFailure.pass` identifies the failed pass; `title`, `message`, and `recoverySuggestion` are the user-facing copy. `canRetryBacks` is true only for a backs-pass failure.

| Failure | Detected | Retry backs? | Recovery |
|---|---|---|---|
| `.invalidDocument` | before submit | no | Choose another PDF. |
| `.printerUnavailable` | preflight / `printer(id:)` | no | Connect printer, enable queue, start over. |
| `.printerStopped(.fronts)` | preflight/monitor | no | Clear error; start over; discard partial fronts. |
| `.printerStopped(.backs)` | pass boundary/monitor | yes | Clear error; retry backs if fronts intact, else start over. |
| `.submitFailed(.fronts)` | `lp` nonzero | no | Fix queue; start over. |
| `.submitFailed(.backs)` | `lp` nonzero | yes | Fix queue; retry backs. |
| `.jobFailed(.fronts)` | terminal canceled/aborted/stopped | no | Remove sheets; start over. |
| `.jobFailed(.backs)` | terminal canceled/aborted/stopped | yes | Verify fronts; retry backs, or start over if any backs printed. |
| `.jobStuck(.fronts)` | no progress 240 s | no | Cancel queue job; start over. |
| `.jobStuck(.backs)` | no progress 240 s | yes, with care | Cancel; retry only if no backs printed, else start over to avoid duplicates. |
| `.monitorFailed(.fronts/.backs)` | `job(id:)` nil or persistent errors | fronts no; backs after verifying | Check queue; start over / retry backs. |
| `.cancelled` | user action | no | Nothing else prints; start over. |
| PPD parse failure | PPD load | n/a | Use system defaults; `ppdNote`; printing still possible. |
| Booklet prep failure | before submit | n/a | Choose another PDF/signature size; show `BookletError`. |
| `CUPSCommandError.toolNotFound` | process launch | n/a | Verify `/usr/bin/lp`/`lpstat`; repair the macOS installation; not recoverable in-app. |
| Queue cancel failure | `spooler.cancel` throws | n/a | Banner; refresh queue; cancel in CUPS. |
| Notifications denied | authorization | n/a | Popover remains primary. |

Never claim success because the queue looks empty or a timer elapsed; only terminal `.completed` completes. Never automatically retry a pass that may have printed sheets; retry backs is an explicit user action after checking the physical stack.

## 11. Testing strategy

**Command builder.** The argv builder inside `CUPSClient` is pure and tested without launching `lp`: `-d`, `-t`, `-n <copies>`, `-o page-set=all/odd/even`, `-o page-ranges=...` when present, `-o number-up=N`, `-o orientation-requested=...`, `-o Duplex=NoTumble/Tumble` for simplex manual passes, PPD driver options, then the file path. Request-owned values are always emitted, even at their defaults, so a queue default cannot silently add copies, 2-up, rotation, or a page subset. CUPS job titles are generic (`FlipStack fronts`, `FlipStack backs`, `FlipStack job`, `FlipStack booklet fronts/backs`); the document name is never sent to CUPS. The queue panel filters to jobs owned by the current user or submitted by this session. No path emits `-o output-order=reverse`; reserved keys in `driverOptions` are rejected/ignored. Use a mock process runner or `@testable` access; no queue required.

**PPD fixtures.** `Tests/FlipStackCoreTests/Fixtures/PPDs/` holds a representative L1800 PPD (ColorModel, PageSize, MediaType, Resolution), a PPD with `Duplex`, a gzipped PPD, a malformed/truncated PPD, and one with no UI options. Tests cover discovery precedence (`/etc/cups/ppd` before the vendor library), OpenUI/choice/default parsing, group mapping, raw values, `isEmpty`, and the no-PPD rule (`driverOptions == []`, `currentDriverOptions == [:]`, no fabricated values). Filesystem tests inject a temporary directory, not real system paths.

**Mock spooler.** `MockPrintSpooler` is an actor implementing `PrintSpooling` with scripted printer/job states; it records every `PrintRequest` and `cancel`. It can return `nil` from `job(id:)`, throw `.timedOut`, or hold `.held`/`.stopped`. `MockDuplexNotifier` records `DuplexNotificationEvent` and asserts exact `.flipRequired` prompts, including `DuplexCopy.flipMessage` and `FlipPrompt.footnote`. The real `BookletImposer` is tested with small PDF fixtures; `PDFPageExtractor` tests verify selected-page order and out-of-range handling.

**Booklet order.** Property tests for `k = 1...6`, `n = 1...64`: every non-blank page appears exactly once; blanks only at the padded end; four slots per spread; `paddedPageCount` is a multiple of 4 and of `4k`; `sheetCount == spreads.count`; signatures partition the padded range. Formula tests against the 8-page and 12-page/`k=2` tables. Golden PDFs: fronts/backs page counts are `2 * sheetCount`; PDFKit order matches the sequences; blanks exist for `nil`; `cleanUp` removes the working directory; `foldHint`/`stapleHint` snapshots for one and multiple signatures.

**State-machine cases.** (1) 6-page happy path fronts -> awaitingFlip -> backs -> completed, with notification order. (2) 5-page path: backs count 2, odd footnote, no fabricated third back. (3) 1-page: no `.awaitingFlip`, completed directly, `hadBlankFinalBack == true`. (4) cancel during fronts: one cancel, no backs, `.cancelled(.fronts)`. (5) cancel at awaitingFlip: no spooler cancel, `.cancelled(.fronts)`, continuation resumed once. (6) cancel during backs: `.cancelled(.backs)`. (7) fronts failure: `.failed`, no flip notification. (8) backs failure: `.failed`, `canRetryBacks`, retry submits only backs. (9) stuck: `.jobStuck` with the right pass. (10) printer stopped between passes: within grace continues, beyond grace `.printerStopped(.backs, reasons)`. (11) job disappears: `.monitorFailed`, never `.completed`. (12) duplicate `confirmFlip`/`cancel` no-ops; no double submit. (13) `reset()` while active rejected; after completion returns to idle. (14) booklet path: fronts/backs files, `numberUp == 2`, `pageSet == .all`, no `page-set`.

`DuplexConfiguration` exposes `pollInterval`, `jobStuckTimeout`, and `printerErrorGracePeriod`; tests use small values (0.01 s, 0.2 s, 0.05 s) for fast, deterministic runs. Real-queue tests are env-gated and not in CI.

**CI.** GitHub Actions on the current `macos-15` runner (Swift 5.9 language mode, Xcode 16 toolchain); `swift test --parallel` and `swift build -c release` on PRs and `main`; cache `.build`; `Package.swift` copies `Fixtures` as resources, so tests never read host `/etc/cups` or `/Library/Printers`. No signing in CI; release is separate and builds both arm64 and x86_64. Manual UI checklist: menu bar, Reduce Motion, VoiceOver, Dynamic Type, calibration at 560/680 and dark mode, notification Continue/Cancel, popover fallback. Live CUPS tests print only counts and generic state; queue names, paths, device URIs, and serials are redacted from output.

## 12. Distribution, signing, notarization, DMG, secrets, update cadence

SwiftPM produces an executable, not an `.app`. A release script assembles `FlipStack.app/Contents/{Info.plist,PkgInfo,MacOS/FlipStack,Resources/AppIcon.icns}`. `Info.plist`: `CFBundlePackageType=APPL`, `CFBundleExecutable=FlipStack`, `CFBundleIdentifier` (e.g. `com.flipstack.app`), `CFBundleShortVersionString`, monotonic `CFBundleVersion`, `LSMinimumSystemVersion=13.0`, `LSUIElement=true`, `NSHighResolutionCapable=true`, `CFBundleIconFile`. `FlipStackMain` and `AppDelegate` set `NSApp.setActivationPolicy(.accessory)`; `LSUIElement` keeps it out of Dock/app switcher. Build universal with `swift build -c release --arch arm64 --arch x86_64` (or `lipo`); verify with `file`/`lipo -info`.

```
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <Team Name> (<TEAMID>)" FlipStack.app
codesign --verify --deep --strict --verbose=2 FlipStack.app

hdiutil create -volname "FlipStack" -srcfolder dist -ov -format UDZO \
  FlipStack-<version>.dmg
xcrun notarytool submit FlipStack-<version>.dmg --keychain-profile flipstack --wait
xcrun stapler staple FlipStack-<version>.dmg
spctl --assess --type open --context context:primary-signature -v FlipStack-<version>.dmg
```

Hardened runtime is required; keep entitlements minimal (no sandbox; no `disable-library-validation`/unsigned-executable-memory unless a real dependency needs it). The DMG contains the app, an `Applications` symlink, and a short readme/license. Notarize the DMG, staple it, publish SHA-256 and notes on GitHub Releases; an optional Homebrew Cask points at the same DMG.

Secrets: never commit certificates or keys. Release uses `MACOS_CERTIFICATE_P12` + `MACOS_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, and `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD` (matching `.github/workflows/release.yml`). Create a temporary keychain with `security create-keychain`, import, `security set-key-partition-list`, and delete it in cleanup; mask logs. Maintainers may use a local `notarytool` keychain profile `flipstack`.

Updates: v1 ships manual GitHub Releases, no background updater. Semantic versioning: patch for regressions, minor for features, major for contract/preference-schema changes; `CFBundleVersion` monotonic and independent of marketing version. If Sparkle 2 is added later: EdDSA-signed appcast over HTTPS, user-approved install, check at launch plus at most once per 24 h, keys handled like notarization secrets. Preference migration must not depend on the updater.

## 13. Per-printer settings schema

`PrinterPreferences` is the per-printer record:

| Field | Type | Values | Meaning |
|---|---|---|---|
| `flipAxis` | `FlipAxis` | `"longEdge"`, `"shortEdge"` | physical axis; `Duplex=NoTumble` / `Tumble` |
| `ejectsFaceDown` | `Bool` | `true`, `false` | selects `reinsertOnly` / `flipBlock` |
| `hasConfiguredFlip` | `Bool` | `true`, `false` | user calibrated this queue; gates first-run setup |

`PrinterPreferences.unconfigured` is `longEdge`, `false`, `false`; `flipMode` is computed (`ejectsFaceDown ? .reinsertOnly : .flipBlock`), not stored.

Example JSON value for queue `EPSON_L1800`:

```json
{
  "flipAxis": "longEdge",
  "ejectsFaceDown": false,
  "hasConfiguredFlip": true
}
```

`PreferencesStore` stores a dictionary keyed by `Printer.id` (the CUPS queue name used by `lp -d`) under `"FlipStack.printerPreferences.v1"`; each value is the JSON above. Logical envelope (illustrative; UserDefaults holds a property-list dictionary whose values are JSON `Data`, not one JSON document):

```json
{
  "FlipStack.printerPreferences.v1": {
    "EPSON_L1800": {
      "flipAxis": "longEdge",
      "ejectsFaceDown": false,
      "hasConfiguredFlip": true
    }
  }
}
```

Separate global keys: `"FlipStack.lastPrinterID"`, `"FlipStack.lastPrintMode.v1"`, `"FlipStack.printerOptions.v1"`, and `"FlipStack.printLayout.v1"` (per-printer PPD choices, validated against the currently loaded PPD before use). `hasConfiguredFlip == false` is meaningful for two-sided modes: `requestPrint` opens `FlipAxisSetup` instead of printing; `completeFlipAxisSetup` saves axis/side and sets the flag; `setEjectsFaceDown` also sets it. A decode failure returns `.unconfigured`; never silently assume a side or axis.

Versioning/migration: the `v1` key suffix is the schema version (v1 JSON has no version field). `FlipAxis` raw values and the boolean keys are stable; do not rename in place. For compatible additions, a future decoder uses `decodeIfPresent` with defaults; `Codable` ignores unknown keys. A future `"FlipStack.printerPreferences.v2"` migrates each v1 record, writes v2, keeps v1 for one release for rollback, and deletes v1 only after a successful write and verified read. Corrupt v1 records are left untouched, return `.unconfigured`, and are not overwritten until the user saves. Queue renames create a new key because `Printer.id` is the queue name; a future migration may match `deviceURI`, but guessing identity is not v1 behavior. Persist PPD driver selections (`ColorModel`, `PageSize`, `MediaType`, `Resolution`) per printer in `"FlipStack.printerOptions.v1"`, but validate every saved keyword and choice against the current PPD on load; stale choices fall back to the PPD default. `copies` is session state, and two-sided modes force one copy. This store is not for secrets. SNMP is read-only and uses the conventional "public" community by default; no credentials are persisted.

## 14. Risks and non-goals

| Risk | Impact | Mitigation |
|---|---|---|
| Face-up/face-down behavior differs by queue/driver | Wrong backside pairing | Per-printer calibration, `hasConfiguredFlip`, explicit prompt, test sheet |
| Odd count leaves the last sheet in the tray | Lost/misplaced final sheet | Footnote, completion hint, "place it on top, blank side up" |
| User touches/fans the stack | Duplicate/missing backs | Exact whole-block instruction; no auto-continue; explicit retry |
| `Duplex=NoTumble/Tumble` honored by a hardware-duplex queue | First pass duplexes unexpectedly | `DuplexConfiguration.forceOneSidedPasses` sends `sides=one-sided` when the PPD advertises hardware duplex |
| `lpstat`/IPP job state missing or history cleared | False success/failure | Never treat empty queue as success; `.monitorFailed` on disappearance |
| Long rasterization pause | False `.jobStuck` | Printer-processing grace; hard cap; reset on any state/reason/impression change |
| Printer error between passes | Backs onto a stopped queue | `printerErrorGracePeriod`, pass-boundary check, `.printerStopped` |
| PPD missing/stale/mismatched | Wrong/rejected options | Queue PPD first; strict fallback; no fabrication; system defaults |
| Malformed/gzipped PPD | Parser crash/hang | Size cap, defensive parser, `ppdNote` |
| Booklet margins/scaling/fold drift | Misaligned spreads | 2-up test sheet; fold/staple hints; no creep claim |
| Booklet padding | Extra sheets | `hasBlankPages`; signature size control |
| Notification denied/Focus mode | Missed flip prompt | Popover primary; `onOpen` before auth; status item indicates waiting |
| App quits during awaiting flip | Flow lost | Notifications not durable; start over; terminate cancels |
| Continuation double-resume/leak | Hang or double backs | Single checked continuation; clear-before-resume; guards; cancellation handler |
| `Process` pipe deadlock/timeout | Hung flow | Read to EOF; timeout/terminate; `CUPSCommandError` |
| IPP/SNMP partial data | Misleading badges | `note`, `StatusOrigin`, unknown supplies omitted |
| Certificate expiry/Gatekeeper | Blocked updates | Calendar reminder; CI release check; stapling verification |
| Universal binary drift | One arch broken | Apple Silicon and Intel CI jobs |
| Accessibility regression | Unusable prompt | Reduce Motion, VoiceOver, Dynamic Type, keyboard checks |

Non-goals: a general print dialog (mode, copies, four PPD groups only); automatic/hardware duplex (manual simplex only); physical-flip verification by sensor/camera/printer feedback; Windows/Linux/iOS/iPadOS; Mac App Store or sandboxed distribution; queue creation, driver installation, firmware, ink ordering, print-server administration; PDF editing/OCR/page-range UI; booklet creep compensation, gutter, crop marks, covers, perfect binding, auto fold/staple; SNMP writes/traps/configuration; cloud, accounts, telemetry; silent background updates in v1; guaranteed support for every PPD or vendor option. The parser exposes what the PPD declares, and nothing more.
