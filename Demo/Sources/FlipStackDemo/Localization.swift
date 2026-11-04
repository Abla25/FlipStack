import Foundation

// MARK: - FlipStack demo localization (EN + IT)
//
// PUBLIC API (used by the UI sweep):
//   * `T("namespace.key")`                       -> localized string
//   * `T("namespace.key", arg1, arg2)`           -> localized + String(format:)
//   * `Units.pages(n)`, `Units.sheets(n)`,
//     `Units.copies(n)`, `Units.jobs(n)`          -> grammar-correct plural phrase
//                                                    ("1 page"/"6 pages", "1 pagina"/"6 pagine")
//   * `L10n.current`                             -> chosen language (default `.en`);
//                                                    set it from the settings screen + persist
//   * `AppLanguage`                              -> `.en` / `.it`, `.shortCode`, `.displayName`
//
// KEY CONVENTION: `<area>.<camelCaseName>`, lower-case, dot separated.
//   areas: a11y, app, calibration, common, doc, error, flow, header, menu,
//          option, options, pages, preview, printer, quality, receipt,
//          settings, toast, unit.
//
// PLACEHOLDERS: `%@` for pre-formatted strings (numbers -> String(n) OR a
// `Units.*` phrase), `%d` for integers, `%1$@`/`%2$@` when an argument order
// could differ between languages. EN and IT must keep the same placeholder
// signature (LocalizationTests enforces this).
//
// FALLBACK: current language -> English -> the key itself (never crashes on a
// missing key; the coverage script still requires zero missing keys).
//
// NOT LOCALIZED ON PURPOSE: `lp` job titles ("FlipStack — fronts", "— backs",
// "— calibration") are matched back by `Printing.findJob`; keep them stable.
// Ink-channel abbreviations (C/M/Y/K/…) come from the printer/PPD, not from us.
//
// CALL-SITE GUIDE (current literal -> key), for the sweep:
//   "Duplex"                               -> receipt.duplex
//   "ON · <EDGE> EDGE" / "OFF"             -> receipt.duplexOn (edge word uppercased) / receipt.duplexOff
//   "Paper"                                -> receipt.paper
//   "Color"                                -> receipt.color
//   "Quality"                              -> receipt.quality
//   "Copies"                               -> receipt.copies
//   "Draft · 180"…                         -> quality.draft / quality.normal / quality.high
//   "*** THANK YOU — DUPLEX DONE RIGHT ***"-> app.tagline
//   "last: %@"                             -> receipt.lastPrint
//   "Drop a document"                      -> doc.dropTitle
//   "PDF · JPEG · HEIC · PNG · DOCX — lossless" -> doc.formats
//   "Choose file"                          -> doc.chooseFile
//   "<n> pages · <x> MB"                   -> doc.meta (Units.pages(n), String(format:"%.1f", mb))
//   "More options"                         -> receipt.moreOptions
//   "▾ 8" / "▸ 8"                          -> receipt.moreOptionsExpanded/Collapsed (%d)
//   "Pages"/"Orientation"/"Scale"/"Media"/"Tray"/"Res. override"/"Ink save"/"Duplex edge"
//                                          -> options.pages / options.orientation / options.scale /
//                                             options.media / options.tray / options.resOverride /
//                                             options.inkSave / options.duplexEdge
//   "Resolution override" (popover title)  -> options.resOverrideTitle
//   "All"/"Odd only"/"Even only"           -> option.pages.all / odd / even
//   "Custom: <spec>"                       -> option.pages.customPrefix ("—" -> common.none)
//   "A4","A3","Letter","Photo 4×6"         -> option.paper.a4/a3/letter/photo4x6
//   "Color"/"B&W"                          -> option.color.color / option.color.bw
//   "long"/"short" + "%@ edge"             -> option.edge.long/short + option.edge.value
//   "auto","portrait","landscape"          -> option.orientation.*
//   "50%",…                                -> option.scale.p50/p75/p100/p125/p150
//   "Plain","Glossy","Photo","Recycled"    -> option.media.*
//   "auto","tray1","tray2"                 -> option.tray.*
//   "Off","<n> dpi"                        -> option.res.off / option.res.dpi
//   "On"/"Off"/"Auto"                      -> common.on / common.off / common.auto
//   "TOTAL" / "<n> SHEETS · <dpi> DPI"     -> receipt.total / receipt.sheetsDpi
//   "PRINT <n> PAGES"                      -> receipt.printButton (Units.pages(n).uppercased())
//   "PAGES" / "Custom (e.g. …)" / "1-…"    -> pages.title / pages.customHint / pages.fieldPlaceholder
//   "Apply <n> pages"                      -> pages.apply (Units.pages(n))
//   "Cancel"                               -> common.cancel
//   "PRINTERS" / "default"                 -> printer.menuTitle / printer.default
//   "offline"/"check printer"/"unknown"    -> header.status.offline/checkPrinter/unknown
//   "idle"/"processing"/"stopped" labels   -> header.state.idle/processing/stopped
//   "· <n> jobs queued"                    -> header.queuedJobs (Units.jobs(n))
//   "via <origin>"                         -> header.via
//   "INK" / "levels unavailable"           -> header.ink / header.inkUnavailable
//   "Preview" / "<name> · <n> pages · <paper>" / "BACK" -> preview.title / preview.meta / preview.back
//   "Select…" / "✓ Selecting" / "<n> selected" -> pages.select / pages.selecting / pages.selectedCount
//   "Printing…"                            -> flow.printing
//   "Flip the stack"                       -> flow.flipTitle
//   "Turn the printed pages over on the <edge> edge, keep the same tray, then confirm."
//                                          -> flow.flipInstructions (option.edge.long/short)
//   "Cancel"/"Retry" (flow bar)            -> common.cancel / common.retry
//   "Reinserted ✓" / "Printed ✓" / "Close" -> flow.reinserted / flow.printed / common.close
//   "Printer: %@"                          -> toast.printerSelected
//   "Drop a document first"                -> toast.dropDocumentFirst
//   "Print failed or cancelled"            -> toast.printFailed
//   "Printed ✓" (toast)                    -> toast.printed
//   "Calibration sheet printed (simulated)"-> toast.calibrationSimulated
//   "Calibration sheet sent to %@"         -> toast.calibrationSent
//   "SETTINGS"/"LANGUAGE"/"DEFAULT QUALITY"/"PRINTER & CALIBRATION"/"ABOUT"
//                                          -> settings.title/language/defaultQuality/printerCalibration/about
//   "Default printer"/"Calibration sheet"/"Run…" -> settings.defaultPrinter / settings.calibrationSheet / common.run
//   "FlipStack <v> (build <b>) — receipt UI" -> settings.version
//   "QUIT FLIPSTACK"                       -> settings.quit
//   "Calibration" + 3-line instructions + "Print calibration sheet"
//                                          -> calibration.title / calibration.instructions / calibration.printSheet
//   Calibration PDF header                 -> calibration.pdfTitle
//   (new v1.0.2) settings menu / status-item menu -> menu.*
//   (new v1.0.2) errors/toasts/pages validation  -> error.* / toast.* / pages.invalidRange/outOfRange/emptySelection
//   (new v1.0.2) accessibility labels             -> a11y.*

// MARK: - Language

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case en
    case it

    var id: String { rawValue }

    /// Two-letter chip label shown in Settings ("EN"/"IT").
    var shortCode: String { rawValue.uppercased() }

    /// Native language name, deliberately not translated.
    var displayName: String {
        switch self {
        case .en: return "English"
        case .it: return "Italiano"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

// MARK: - Tables

enum L10n {
    /// Currently active language. The settings screen sets this (and should
    /// persist `rawValue` in UserDefaults, e.g. key "FlipStack.demo.language").
    static var current: AppLanguage = .en

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .en: return english
        case .it: return italian
        }
    }

    /// Every key that exists in at least one table. Tests assert the two
    /// tables expose the identical key set, so this is the full contract.
    static var allKeys: Set<String> { Set(english.keys).union(italian.keys) }

    /// Keys requested by the coverage script that are absent from a table
    /// (does not consider the EN fallback, by design).
    static func missingKeys(in keys: Set<String>, language: AppLanguage? = nil) -> [String] {
        let table = table(for: language ?? current)
        return keys.filter { table[$0] == nil }.sorted()
    }

    /**
     Localized value for `key` in the current language.

     Resolution order: current language -> English -> the key itself.
     */
    static func string(for key: String) -> String {
        if let value = table(for: current)[key] { return value }
        if let fallback = english[key] { return fallback }
        return key
    }

    // MARK: English (source of truth — reproduces the v1.0.1 UI exactly,
    // except where a plural helper deliberately fixes "1 pages" -> "1 page")

    static let english: [String: String] = [
        "a11y.cancelPrint": "Cancel print",
        "a11y.chooseDocument": "Choose a document",
        "a11y.closePanel": "Close panel",
        "a11y.closePreview": "Close preview",
        "a11y.excludePage": "Page %d, excluded",
        "a11y.flipStack": "Flip stack",
        "a11y.includePage": "Page %d, included",
        "a11y.inkLevels": "Ink levels",
        "a11y.moreOptions": "Show more options",
        "a11y.page": "Page %d",
        "a11y.previewDocument": "Preview document",
        "a11y.print": "Print",
        "a11y.printerStatus": "Printer status: %@",
        "a11y.progress": "Print progress",
        "a11y.retryPrint": "Retry print",
        "a11y.settings": "Settings",
        "a11y.statusItem": "FlipStack print manager",
        "a11y.statusItemHelp": "Open the FlipStack receipt panel.",
        "app.name": "FlipStack",
        "app.tagline": "*** THANK YOU — DUPLEX DONE RIGHT ***",
        "calibration.closeA11y": "Close calibration",
        "calibration.instructions": "1. Print the calibration sheet on plain A4.\n2. Mark the sharpest line block and the aligned pair.\n3. FlipStack stores the offsets for duplex registration.",
        "calibration.pdfTitle": "FLIPSTACK CALIBRATION — mark sharpest line & aligned pair",
        "calibration.printSheet": "Print calibration sheet",
        "calibration.title": "Calibration",
        "common.apply": "Apply",
        "common.auto": "Auto",
        "common.cancel": "Cancel",
        "common.close": "Close",
        "common.next": "Next",
        "common.none": "—",
        "common.off": "Off",
        "common.on": "On",
        "common.previous": "Previous",
        "common.refresh": "Refresh",
        "common.retry": "Retry",
        "common.run": "Run…",
        "doc.chooseFile": "Choose file",
        "doc.dropTitle": "Drop a document",
        "doc.formats": "PDF · JPEG · HEIC · PNG · DOCX — lossless",
        "doc.formatsLong": "PDF · photos · Word · text — lossless",
        "doc.meta": "%@ · %@ MB",
        "doc.openPanelTitle": "Choose a document",
        "doc.removeA11y": "Remove document",
        "error.conversionFailed": "Could not convert “%@”.",
        "error.detail": "Details: %@",
        "error.documentNoPages": "This document has no printable pages.",
        "error.invalidRange": "Invalid page range.",
        "error.listPrintersFailed": "Could not list printers.",
        "error.noPages": "Select at least one page to print.",
        "error.noPrinter": "No printer selected. Choose a printer first.",
        "error.printerOffline": "This printer looks offline.",
        "error.printFailed": "Print failed. Check the printer and try again.",
        "error.unreadableFile": "Could not read “%@”.",
        "error.unsupportedFile": "Unsupported file type. Use PDF, images, Word or text documents.",
        "flow.announceCancelled": "Printing cancelled.",
        "flow.announceDone": "Printing complete.",
        "flow.announceFailed": "Printing failed.",
        "flow.announceFlip": "Your turn. Flip the stack on the %@ edge, then confirm.",
        "flow.announcePrinting": "Printing %@.",
        "flow.flipInstructions": "Turn the printed pages over on the %@ edge, keep the same tray, then confirm.",
        "flow.flipTitle": "Flip the stack",
        "flow.lastPrint": "%@ · %d %@ → %@ at %@",
        "flow.printed": "Printed ✓",
        "flow.printing": "Printing…",
        "flow.printingBacks": "Printing backs…",
        "flow.printingFronts": "Printing fronts…",
        "flow.reinserted": "Reinserted ✓",
        "header.ink": "INK",
        "header.inkUnavailable": "levels unavailable",
        "header.queuedJobs": "· %@ queued",
        "header.state.idle": "ready",
        "header.state.processing": "printing",
        "header.state.stopped": "stopped",
        "header.status.checkPrinter": "check printer",
        "header.status.offline": "offline",
        "header.status.unknown": "unknown",
        "header.via": "via %@",
        "menu.about": "About FlipStack",
        "menu.open": "Open FlipStack",
        "menu.quit": "Quit FlipStack",
        "menu.settings": "Settings…",
        "option.color.bw": "B&W",
        "option.color.color": "Color",
        "option.edge.long": "long",
        "option.edge.short": "short",
        "option.edge.value": "%@ edge",
        "option.media.glossy": "Glossy",
        "option.media.photo": "Photo",
        "option.media.plain": "Plain",
        "option.media.recycled": "Recycled",
        "option.orientation.auto": "auto",
        "option.orientation.landscape": "landscape",
        "option.orientation.portrait": "portrait",
        "option.pages.all": "All",
        "option.pages.customPrefix": "Custom: %@",
        "option.pages.even": "Even only",
        "option.pages.odd": "Odd only",
        "option.paper.a3": "A3",
        "option.paper.a4": "A4",
        "option.paper.letter": "Letter",
        "option.paper.photo4x6": "Photo 4×6",
        "option.res.dpi": "%@ dpi",
        "option.res.off": "Off",
        "option.scale.p100": "100%",
        "option.scale.p125": "125%",
        "option.scale.p150": "150%",
        "option.scale.p50": "50%",
        "option.scale.p75": "75%",
        "option.tray.auto": "auto",
        "option.tray.tray1": "tray1",
        "option.tray.tray2": "tray2",
        "options.duplexEdge": "Duplex edge",
        "options.inkSave": "Ink save",
        "options.media": "Media",
        "options.orientation": "Orientation",
        "options.pages": "Pages",
        "options.resOverride": "Res. override",
        "options.resOverrideTitle": "Resolution override",
        "options.scale": "Scale",
        "options.tray": "Tray",
        "pages.apply": "Apply",
        "pages.customHint": "Custom (e.g. 1-5, 8, 12-14)",
        "pages.emptySelection": "Select at least one page",
        "pages.fieldPlaceholder": "1-…",
        "pages.invalidRange": "Invalid range — try “1-5, 8”",
        "pages.nextA11y": "Next page",
        "pages.outOfRange": "Some pages are outside this document",
        "pages.previousA11y": "Previous page",
        "pages.select": "Select…",
        "pages.selectedCount": "%d selected",
        "pages.selecting": "✓ Selecting",
        "pages.title": "PAGES",
        "preview.back": "BACK",
        "preview.front": "FRONT",
        "preview.meta": "%1$@ · %2$@ · %3$@",
        "preview.title": "Preview",
        "preview.zoomIn": "Zoom in",
        "preview.zoomOut": "Zoom out",
        "printer.default": "default",
        "printer.defaultShort": "default",
        "printer.menuTitle": "PRINTERS",
        "printer.none": "No printers found",
        "printer.noneHint": "Add a printer in System Settings, then refresh.",
        "printer.queued": "%@ queued",
        "quality.draft": "Draft · 180",
        "quality.high": "High · 600",
        "quality.normal": "Normal · 366",
        "receipt.color": "Color",
        "receipt.copies": "Copies",
        "receipt.duplex": "Duplex",
        "receipt.duplexOff": "OFF",
        "receipt.duplexOn": "ON · %@ EDGE",
        "receipt.lastPrint": "last: %@",
        "receipt.moreOptions": "More options",
        "receipt.moreOptionsCollapsed": "▸ %d",
        "receipt.moreOptionsExpanded": "▾ %d",
        "receipt.paper": "Paper",
        "receipt.printButton": "PRINT %@",
        "receipt.quality": "Quality",
        "receipt.sheetsDpi": "%@ · %@ DPI",
        "receipt.total": "TOTAL",
        "settings.about": "ABOUT",
        "settings.calibrationSheet": "Calibration",
        "settings.closeA11y": "Close settings",
        "settings.defaultPrinter": "Default printer",
        "settings.defaultQuality": "DEFAULT QUALITY",
        "settings.defaultQualityA11y": "Default quality: %@",
        "settings.language": "LANGUAGE",
        "settings.languageA11y": "Language: %@",
        "settings.printerCalibration": "PRINTER & CALIBRATION",
        "settings.quit": "QUIT FLIPSTACK",
        "settings.remember": "Remember these settings",
        "settings.reset": "Reset",
        "settings.title": "SETTINGS",
        "settings.version": "FlipStack %@ (build %@) — receipt UI",
        "settings.versionDev": "FlipStack — dev build",
        "toast.calibrationSent": "Calibration sheet sent to the printer",
        "toast.calibrationSimulated": "Calibration sheet printed (simulated)",
        "toast.cancelled": "Print cancelled",
        "toast.documentEmpty": "This document has no printable pages",
        "toast.dropDocumentFirst": "Drop a document first",
        "toast.fileUnreadable": "Could not open “%@”",
        "toast.fileUnsupported": "That file type isn’t supported",
        "toast.noPages": "Select at least one page",
        "toast.noPrinter": "No printer selected",
        "toast.offline": "Printer looks offline — printing anyway",
        "toast.printFailed": "Print failed or cancelled",
        "toast.printFailedDetail": "Print failed — check the printer",
        "toast.printed": "Printed ✓",
        "toast.printerSelected": "Printer: %@",
        "toast.retrying": "Retrying…",
        "toast.stillPrinting": "Still printing — check the printer",
        "unit.copies.one": "%d copy",
        "unit.copies.other": "%d copies",
        "unit.jobs.one": "%d job",
        "unit.jobs.other": "%d jobs",
        "unit.pages.one": "%d page",
        "unit.pages.other": "%d pages",
        "unit.pagesShort": "pg",
        "unit.sheets.one": "%d sheet",
        "app.tooltip": "FlipStack receipt panel",
        "calib.instructions": "1. Print the calibration sheet on plain A4.\n2. Mark the sharpest line block and the aligned pair.\n3. FlipStack stores the offsets for duplex registration.",
        "calib.print": "Print calibration sheet",
        "calib.printed.simulated": "Calibration sheet printed (simulated)",
        "calib.sent": "Calibration sheet sent to",
        "calib.title": "Calibration",
        "common.edit": "Click to change",
        "common.pages": "pages",
        "common.remove": "Remove document",
        "flow.cancel": "Cancel",
        "flow.done": "Printed ✓",
        "flow.flip.body": "Turn the printed pages over on the",
        "flow.flip.body2": "edge, keep the same tray, then confirm.",
        "flow.flip.confirm": "Reinserted ✓",
        "flow.flip.title": "Flip the stack",
        "flow.retry": "Retry",
        "more.help": "Show advanced print options",
        "more.title": "More options",
        "option.auto": "Auto",
        "option.bw": "B&W",
        "option.color": "Color",
        "option.color.title": "Color",
        "option.copies": "Copies",
        "option.copies.title": "Copies",
        "option.duplex": "Duplex",
        "option.duplexEdge": "Duplex edge",
        "option.duplexEdge.title": "Duplex edge",
        "option.edge": "edge",
        "option.inkSave": "Ink save",
        "option.inkSave.title": "Ink save",
        "option.media": "Media",
        "option.media.title": "Media",
        "option.off": "Off",
        "option.on": "On",
        "option.orientation": "Orientation",
        "option.orientation.title": "Orientation",
        "option.pages": "Pages",
        "option.paper": "Paper",
        "option.paper.title": "Paper",
        "option.quality": "Quality",
        "option.quality.draft": "Draft · 180",
        "option.quality.high": "High · 600",
        "option.quality.normal": "Normal · 366",
        "option.quality.title": "Quality",
        "option.resOverride": "Res. override",
        "option.resOverride.title": "Resolution override",
        "option.scale": "Scale",
        "option.scale.title": "Scale",
        "option.tray": "Tray",
        "option.tray.title": "Tray",
        "pages.custom": "Custom",
        "pages.decrease": "Decrease",
        "pages.error.noDoc": "Open a document to choose a page range",
        "pages.error.range": "From must be ≤ To",
        "pages.from": "From",
        "pages.increase": "Increase",
        "pages.select.a11y": "Select pages",
        "pages.select.help": "Toggle pages in the print set",
        "pages.to": "To",
        "preview.back.a11y": "Back side of the sheet",
        "preview.next": "Next page",
        "preview.open": "Open preview",
        "preview.open.help": "Click to enlarge the preview",
        "preview.prev": "Previous page",
        "printers.change": "Change printer",
        "printers.default": "default",
        "printers.empty": "No printers found",
        "printers.job": "job",
        "printers.jobs": "jobs",
        "printers.loading": "Looking for printers…",
        "printers.none.help": "No printer selected",
        "printers.queued": "queued",
        "printers.refresh": "Refresh printers",
        "printers.title": "PRINTERS",
        "receipt.chooseFile": "Choose file",
        "receipt.drop": "Drop a document",
        "receipt.drop.formats": "PDF · JPEG · HEIC · PNG · DOCX — lossless",
        "receipt.last": "last:",
        "receipt.page": "PAGE",
        "receipt.pages": "PAGES",
        "receipt.print": "PRINT",
        "receipt.sheet": "SHEET",
        "receipt.sheets": "SHEETS",
        "receipt.thanks": "*** THANK YOU — DUPLEX DONE RIGHT ***",
        "settings.about.suffix": "— receipt UI",
        "settings.calibration": "Calibration sheet",
        "settings.calibration.run": "Run…",
        "settings.open": "Settings",
        "settings.quality": "DEFAULT QUALITY",
        "status.checkPrinter": "check printer",
        "status.checkPrinterShort": "check",
        "status.offline": "offline",
        "status.printing": "printing",
        "status.ready": "ready",
        "status.stopped": "stopped",
        "status.unknown": "unknown",
        "toast.cannotConfirm": "Printing status unknown — check the printer",
        "toast.conversionFailed": "Could not convert that file",
        "toast.noDocument": "Drop a document first",
        "toast.offlineWarning": "Printer looks offline — printing anyway",
        "toast.printer": "Printer",
        "toast.unsupportedFile": "That file type isn’t supported",
        "a11y.decrease": "Decrease",
        "a11y.increase": "Increase",
        "common.clickToChange": "Click to change",
        "preview.openHelp": "Click to enlarge the preview",
        "printer.change": "Change printer",
        "printer.loading": "Looking for printers…",
        "printer.refreshA11y": "Refresh printers",
        "unit.sheets.other": "%d sheets",
    ]

    // MARK: Italian (natural receipt tone; same key set, same placeholders)

    static let italian: [String: String] = [
        "a11y.cancelPrint": "Annulla stampa",
        "a11y.chooseDocument": "Scegli un documento",
        "a11y.closePanel": "Chiudi pannello",
        "a11y.closePreview": "Chiudi anteprima",
        "a11y.excludePage": "Pagina %d, esclusa",
        "a11y.flipStack": "Capovolgi risma",
        "a11y.includePage": "Pagina %d, inclusa",
        "a11y.inkLevels": "Livelli di inchiostro",
        "a11y.moreOptions": "Mostra altre opzioni",
        "a11y.page": "Pagina %d",
        "a11y.previewDocument": "Anteprima documento",
        "a11y.print": "Stampa",
        "a11y.printerStatus": "Stato stampante: %@",
        "a11y.progress": "Avanzamento stampa",
        "a11y.retryPrint": "Riprova stampa",
        "a11y.settings": "Impostazioni",
        "a11y.statusItem": "Gestore di stampa FlipStack",
        "a11y.statusItemHelp": "Apri il pannello scontrino di FlipStack.",
        "app.name": "FlipStack",
        "app.tagline": "*** GRAZIE — FRONTE-RETRO FATTO BENE ***",
        "calibration.closeA11y": "Chiudi calibrazione",
        "calibration.instructions": "1. Stampa il foglio di calibrazione su carta A4 semplice.\n2. Segna il blocco di linee più nitido e la coppia allineata.\n3. FlipStack memorizza gli scostamenti per l’allineamento fronte-retro.",
        "calibration.pdfTitle": "CALIBRAZIONE FLIPSTACK — segna la linea più nitida e la coppia allineata",
        "calibration.printSheet": "Stampa foglio di calibrazione",
        "calibration.title": "Calibrazione",
        "common.apply": "Applica",
        "common.auto": "Auto",
        "common.cancel": "Annulla",
        "common.close": "Chiudi",
        "common.next": "Successivo",
        "common.none": "—",
        "common.off": "No",
        "common.on": "Sì",
        "common.previous": "Precedente",
        "common.refresh": "Aggiorna",
        "common.retry": "Riprova",
        "common.run": "Avvia…",
        "doc.chooseFile": "Scegli file",
        "doc.dropTitle": "Trascina un documento",
        "doc.formats": "PDF · JPEG · HEIC · PNG · DOCX — senza perdita",
        "doc.formatsLong": "PDF · foto · Word · testo — senza perdita",
        "doc.meta": "%@ · %@ MB",
        "doc.openPanelTitle": "Scegli un documento",
        "doc.removeA11y": "Rimuovi documento",
        "error.conversionFailed": "Impossibile convertire “%@”.",
        "error.detail": "Dettagli: %@",
        "error.documentNoPages": "Questo documento non ha pagine stampabili.",
        "error.invalidRange": "Intervallo di pagine non valido.",
        "error.listPrintersFailed": "Impossibile elencare le stampanti.",
        "error.noPages": "Seleziona almeno una pagina da stampare.",
        "error.noPrinter": "Nessuna stampante selezionata. Scegli una stampante prima di stampare.",
        "error.printerOffline": "Questa stampante sembra offline.",
        "error.printFailed": "Stampa non riuscita. Controlla la stampante e riprova.",
        "error.unreadableFile": "Impossibile leggere “%@”.",
        "error.unsupportedFile": "Tipo di file non supportato. Usa PDF, immagini, documenti Word o testo.",
        "flow.announceCancelled": "Stampa annullata.",
        "flow.announceDone": "Stampa completata.",
        "flow.announceFailed": "Stampa non riuscita.",
        "flow.announceFlip": "Tocca a te. Capovolgi la risma sul bordo %@, poi conferma.",
        "flow.announcePrinting": "Stampa di %@.",
        "flow.flipInstructions": "Capovolgi i fogli stampati sul bordo %@, usa lo stesso vassoio, poi conferma.",
        "flow.flipTitle": "Capovolgi la risma",
        "flow.lastPrint": "%@ · %d %@ → %@ alle %@",
        "flow.printed": "Stampato ✓",
        "flow.printing": "Stampa in corso…",
        "flow.printingBacks": "Stampa dei retri…",
        "flow.printingFronts": "Stampa dei fronti…",
        "flow.reinserted": "Reinserito ✓",
        "header.ink": "INCHIOSTRO",
        "header.inkUnavailable": "livelli non disponibili",
        "header.queuedJobs": "· %@ in coda",
        "header.state.idle": "pronta",
        "header.state.processing": "in stampa",
        "header.state.stopped": "in pausa",
        "header.status.checkPrinter": "controlla stampante",
        "header.status.offline": "offline",
        "header.status.unknown": "sconosciuta",
        "header.via": "via %@",
        "menu.about": "Informazioni su FlipStack",
        "menu.open": "Apri FlipStack",
        "menu.quit": "Esci da FlipStack",
        "menu.settings": "Impostazioni…",
        "option.color.bw": "Bianco e nero",
        "option.color.color": "Colore",
        "option.edge.long": "lungo",
        "option.edge.short": "corto",
        "option.edge.value": "bordo %@",
        "option.media.glossy": "Lucida",
        "option.media.photo": "Fotografica",
        "option.media.plain": "Normale",
        "option.media.recycled": "Riciclata",
        "option.orientation.auto": "automatico",
        "option.orientation.landscape": "orizzontale",
        "option.orientation.portrait": "verticale",
        "option.pages.all": "Tutte",
        "option.pages.customPrefix": "Personalizzate: %@",
        "option.pages.even": "Solo pari",
        "option.pages.odd": "Solo dispari",
        "option.paper.a3": "A3",
        "option.paper.a4": "A4",
        "option.paper.letter": "Letter",
        "option.paper.photo4x6": "Foto 10×15",
        "option.res.dpi": "%@ dpi",
        "option.res.off": "No",
        "option.scale.p100": "100%",
        "option.scale.p125": "125%",
        "option.scale.p150": "150%",
        "option.scale.p50": "50%",
        "option.scale.p75": "75%",
        "option.tray.auto": "automatico",
        "option.tray.tray1": "vassoio 1",
        "option.tray.tray2": "vassoio 2",
        "options.duplexEdge": "Bordo fronte-retro",
        "options.inkSave": "Risparmio inchiostro",
        "options.media": "Supporto",
        "options.orientation": "Orientamento",
        "options.pages": "Pagine",
        "options.resOverride": "Risoluzione",
        "options.resOverrideTitle": "Risoluzione",
        "options.scale": "Scala",
        "options.tray": "Vassoio",
        "pages.apply": "Applica",
        "pages.customHint": "Personalizzate (es. 1-5, 8, 12-14)",
        "pages.emptySelection": "Seleziona almeno una pagina",
        "pages.fieldPlaceholder": "1-…",
        "pages.invalidRange": "Intervallo non valido — prova “1-5, 8”",
        "pages.nextA11y": "Pagina successiva",
        "pages.outOfRange": "Alcune pagine sono fuori dal documento",
        "pages.previousA11y": "Pagina precedente",
        "pages.select": "Seleziona…",
        "pages.selectedCount": "%d selezionate",
        "pages.selecting": "✓ Selezione",
        "pages.title": "PAGINE",
        "preview.back": "RETRO",
        "preview.front": "FRONTE",
        "preview.meta": "%1$@ · %2$@ · %3$@",
        "preview.title": "Anteprima",
        "preview.zoomIn": "Ingrandisci",
        "preview.zoomOut": "Riduci",
        "printer.default": "predefinita",
        "printer.defaultShort": "default",
        "printer.menuTitle": "STAMPANTI",
        "printer.none": "Nessuna stampante trovata",
        "printer.noneHint": "Aggiungi una stampante in Impostazioni di Sistema, poi aggiorna.",
        "printer.queued": "%@ in coda",
        "quality.draft": "Bozza · 180",
        "quality.high": "Alta · 600",
        "quality.normal": "Normale · 366",
        "receipt.color": "Colore",
        "receipt.copies": "Copie",
        "receipt.duplex": "Fronte-retro",
        "receipt.duplexOff": "NO",
        "receipt.duplexOn": "SÌ · %@",
        "receipt.lastPrint": "ultima: %@",
        "receipt.moreOptions": "Altre opzioni",
        "receipt.moreOptionsCollapsed": "▸ %d",
        "receipt.moreOptionsExpanded": "▾ %d",
        "receipt.paper": "Carta",
        "receipt.printButton": "STAMPA %@",
        "receipt.quality": "Qualità",
        "receipt.sheetsDpi": "%@ · %@ DPI",
        "receipt.total": "TOTALE",
        "settings.about": "INFORMAZIONI",
        "settings.calibrationSheet": "Calibrazione",
        "settings.closeA11y": "Chiudi impostazioni",
        "settings.defaultPrinter": "Stampante predefinita",
        "settings.defaultQuality": "QUALITÀ PREDEFINITA",
        "settings.defaultQualityA11y": "Qualità predefinita: %@",
        "settings.language": "LINGUA",
        "settings.languageA11y": "Lingua: %@",
        "settings.printerCalibration": "STAMPANTE E CALIBRAZIONE",
        "settings.quit": "ESCI DA FLIPSTACK",
        "settings.remember": "Ricorda queste impostazioni",
        "settings.reset": "Reimposta",
        "settings.title": "IMPOSTAZIONI",
        "settings.version": "FlipStack %@ (build %@) — interfaccia scontrino",
        "settings.versionDev": "FlipStack — build di sviluppo",
        "toast.calibrationSent": "Foglio di calibrazione inviato alla stampante",
        "toast.calibrationSimulated": "Foglio di calibrazione stampato (simulato)",
        "toast.cancelled": "Stampa annullata",
        "toast.documentEmpty": "Questo documento non ha pagine stampabili",
        "toast.dropDocumentFirst": "Prima trascina un documento",
        "toast.fileUnreadable": "Impossibile aprire “%@”",
        "toast.fileUnsupported": "Questo tipo di file non è supportato",
        "toast.noPages": "Seleziona almeno una pagina",
        "toast.noPrinter": "Nessuna stampante selezionata",
        "toast.offline": "La stampante sembra offline — stampo comunque",
        "toast.printFailed": "Stampa non riuscita o annullata",
        "toast.printFailedDetail": "Stampa non riuscita — controlla la stampante",
        "toast.printed": "Stampato ✓",
        "toast.printerSelected": "Stampante: %@",
        "toast.retrying": "Nuovo tentativo…",
        "toast.stillPrinting": "Stampa ancora in corso — controlla la stampante",
        "unit.copies.one": "%d copia",
        "unit.copies.other": "%d copie",
        "unit.jobs.one": "%d lavoro",
        "unit.jobs.other": "%d lavori",
        "unit.pages.one": "%d pagina",
        "unit.pages.other": "%d pagine",
        "unit.pagesShort": "pagg.",
        "unit.sheets.one": "%d foglio",
        "app.tooltip": "Pannello scontrino FlipStack",
        "calib.instructions": "1. Stampa il foglio di calibrazione su carta A4 semplice.\n2. Segna il blocco di linee più nitido e la coppia allineata.\n3. FlipStack memorizza gli scostamenti per l’allineamento fronte-retro.",
        "calib.print": "Stampa foglio di calibrazione",
        "calib.printed.simulated": "Foglio di calibrazione stampato (simulato)",
        "calib.sent": "Foglio di calibrazione inviato a",
        "calib.title": "Calibrazione",
        "common.edit": "Clicca per modificare",
        "common.pages": "pagine",
        "common.remove": "Rimuovi documento",
        "flow.cancel": "Annulla",
        "flow.done": "Stampato ✓",
        "flow.flip.body": "Capovolgi i fogli stampati sul bordo",
        "flow.flip.body2": "e usa lo stesso vassoio, poi conferma.",
        "flow.flip.confirm": "Reinserito ✓",
        "flow.flip.title": "Capovolgi la risma",
        "flow.retry": "Riprova",
        "more.help": "Mostra opzioni di stampa avanzate",
        "more.title": "Altre opzioni",
        "option.auto": "Automatico",
        "option.bw": "Bianco e nero",
        "option.color": "Colore",
        "option.color.title": "Colore",
        "option.copies": "Copie",
        "option.copies.title": "Copie",
        "option.duplex": "Fronte-retro",
        "option.duplexEdge": "Bordo fronte-retro",
        "option.duplexEdge.title": "Bordo fronte-retro",
        "option.edge": "bordo",
        "option.inkSave": "Risparmio inchiostro",
        "option.inkSave.title": "Risparmio inchiostro",
        "option.media": "Supporto",
        "option.media.title": "Supporto",
        "option.off": "No",
        "option.on": "Sì",
        "option.orientation": "Orientamento",
        "option.orientation.title": "Orientamento",
        "option.pages": "Pagine",
        "option.paper": "Carta",
        "option.paper.title": "Carta",
        "option.quality": "Qualità",
        "option.quality.draft": "Bozza · 180",
        "option.quality.high": "Alta · 600",
        "option.quality.normal": "Normale · 366",
        "option.quality.title": "Qualità",
        "option.resOverride": "Risoluzione",
        "option.resOverride.title": "Risoluzione",
        "option.scale": "Scala",
        "option.scale.title": "Scala",
        "option.tray": "Vassoio",
        "option.tray.title": "Vassoio",
        "pages.custom": "Personalizzate",
        "pages.decrease": "Riduci",
        "pages.error.noDoc": "Apri un documento per scegliere un intervallo di pagine",
        "pages.error.range": "Da deve essere ≤ A",
        "pages.from": "Da",
        "pages.increase": "Aumenta",
        "pages.select.a11y": "Seleziona pagine",
        "pages.select.help": "Includi o escludi pagine dalla stampa",
        "pages.to": "A",
        "preview.back.a11y": "Lato retro del foglio",
        "preview.next": "Pagina successiva",
        "preview.open": "Apri anteprima",
        "preview.open.help": "Clicca per ingrandire l’anteprima",
        "preview.prev": "Pagina precedente",
        "printers.change": "Cambia stampante",
        "printers.default": "predefinita",
        "printers.empty": "Nessuna stampante trovata",
        "printers.job": "lavoro",
        "printers.jobs": "lavori",
        "printers.loading": "Ricerca stampanti…",
        "printers.none.help": "Nessuna stampante selezionata",
        "printers.queued": "in coda",
        "printers.refresh": "Aggiorna stampanti",
        "printers.title": "STAMPANTI",
        "receipt.chooseFile": "Scegli file",
        "receipt.drop": "Trascina un documento",
        "receipt.drop.formats": "PDF · JPEG · HEIC · PNG · DOCX — senza perdita",
        "receipt.last": "ultima:",
        "receipt.page": "PAGINA",
        "receipt.pages": "PAGINE",
        "receipt.print": "STAMPA",
        "receipt.sheet": "FOGLIO",
        "receipt.sheets": "FOGLI",
        "receipt.thanks": "*** GRAZIE — FRONTE-RETRO FATTO BENE ***",
        "settings.about.suffix": "— interfaccia scontrino",
        "settings.calibration": "Calibrazione",
        "settings.calibration.run": "Avvia…",
        "settings.open": "Impostazioni",
        "settings.quality": "QUALITÀ PREDEFINITA",
        "status.checkPrinter": "controlla stampante",
        "status.checkPrinterShort": "controlla",
        "status.offline": "offline",
        "status.printing": "in stampa",
        "status.ready": "pronta",
        "status.stopped": "in pausa",
        "status.unknown": "sconosciuta",
        "toast.cannotConfirm": "Stato di stampa sconosciuto — controlla la stampante",
        "toast.conversionFailed": "Impossibile convertire il file",
        "toast.noDocument": "Prima trascina un documento",
        "toast.offlineWarning": "La stampante sembra offline — stampo comunque",
        "toast.printer": "Stampante",
        "toast.unsupportedFile": "Questo tipo di file non è supportato",
        "a11y.decrease": "Riduci",
        "a11y.increase": "Aumenta",
        "common.clickToChange": "Clicca per modificare",
        "preview.openHelp": "Clicca per ingrandire l’anteprima",
        "printer.change": "Cambia stampante",
        "printer.loading": "Ricerca stampanti…",
        "printer.refreshA11y": "Aggiorna stampanti",
        "unit.sheets.other": "%d fogli",
    ]
}

// MARK: - T()

/**
 Localizes `key` and, when format arguments are supplied, applies
 `String(format:)` with the current language's format string.

 Usage:
     T("receipt.printButton", Units.pages(count).uppercased())
     T("flow.flipInstructions", T("option.edge.long"))
     T("toast.printerSelected", model.printerName)
     T("pages.invalidRange")
 */
func T(_ key: String, _ arguments: CVarArg...) -> String {
    let template = L10n.string(for: key)
    guard !arguments.isEmpty else { return template }
    return String(format: template, arguments: arguments)
}

// MARK: - Grammar helpers

/// Grammar-correct plural phrases. The choice of singular/plural follows the
/// current language ("1 page"/"2 pages", "1 pagina"/"2 pagine").
enum Units {
    static func pages(_ count: Int) -> String { plural("unit.pages", count) }
    static func sheets(_ count: Int) -> String { plural("unit.sheets", count) }
    static func copies(_ count: Int) -> String { plural("unit.copies", count) }
    static func jobs(_ count: Int) -> String { plural("unit.jobs", count) }

    /// Short page unit for dense lines ("pg"/"pagg.").
    static var pagesShort: String { T("unit.pagesShort") }

    private static func plural(_ prefix: String, _ count: Int) -> String {
        let key = count == 1 ? "\(prefix).one" : "\(prefix).other"
        return T(key, count)
    }
}

// MARK: - Compatibility API (skeleton surface + UI-sweep helper)

/// Alias for `T(_:)`; kept because the localization skeleton exposes `t(...)`.
func t(_ key: String, _ arguments: CVarArg...) -> String {
    let template = L10n.string(for: key)
    guard !arguments.isEmpty else { return template }
    return String(format: template, arguments: arguments)
}

extension L10n {
    /// Skeleton table names (implementation tables are `english`/`italian`).
    static var enTable: [String: String] { english }
    static var itTable: [String: String] { italian }

    /// Plural helpers used by `Model.finishFlow` (`L10n.sheets`/`L10n.pages`).
    static func pages(_ count: Int) -> String { Units.pages(count) }
    static func sheets(_ count: Int) -> String { Units.sheets(count) }
    static func copies(_ count: Int) -> String { Units.copies(count) }
    static func jobs(_ count: Int) -> String { Units.jobs(count) }

    /// Runs `body` with `language` active, restoring the previous language
    /// afterwards. Used by tests and by preview/screenshot rendering.
    static func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let previous = current
        current = language
        defer { current = previous }
        return try body()
    }

    /// Whether `key` exists in at least one language table.
    static func hasKey(_ key: String) -> Bool {
        english[key] != nil || italian[key] != nil
    }

    /// Transitional helper for the UI sweep (`uiText("key", "Current English")`
    /// in the views). Returns the localized value when the key exists in the
    /// current language or in English; otherwise returns the literal fallback
    /// so a partly-swept UI keeps rendering. `Components.swift`'s `uiText`
    /// stub should delegate here: `{ L10n.uiString($0, $1) }`.
    static func uiString(_ key: String, _ fallback: String) -> String {
        if table(for: current)[key] != nil || english[key] != nil {
            return string(for: key)
        }
        return fallback
    }
}
