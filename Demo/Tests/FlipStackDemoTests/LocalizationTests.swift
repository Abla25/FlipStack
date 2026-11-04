import XCTest
@testable import FlipStackDemo

/// Tests for the demo localization layer (`Localization.swift`).
///
/// The contract enforced here:
/// 1. EN and IT tables expose the *identical* key set.
/// 2. No value is empty/whitespace-only.
/// 3. Placeholder signatures (`%@`, `%d`, positional `%n$@`) match per key.
/// 4. Every `T("…")` / `t("…")` / `uiText("…")` key used in
///    `Demo/Sources/FlipStackDemo` exists in both tables (source coverage).
///    This mirrors the external grep coverage script and is the reason the
///    tables stay one-key-per-line (grep/sed friendly).
/// 5. A sample of EN strings reproduces the v1.0.1 receipt UI exactly and a
///    sample of IT strings is natural Italian.
/// 6. Plural helpers (`Units.*` / `L10n.*`) are grammatically correct.
final class LocalizationTests: XCTestCase {
    private var english: [String: String] = [:]
    private var italian: [String: String] = [:]

    override func setUp() {
        super.setUp()
        L10n.current = .en
        english = L10n.english
        italian = L10n.italian
    }

    override func tearDown() {
        L10n.current = .en
        english = [:]
        italian = [:]
        super.tearDown()
    }

    // MARK: - Table contract

    func testEnglishAndItalianTablesExposeIdenticalKeySets() {
        let enKeys = Set(english.keys)
        let itKeys = Set(italian.keys)
        XCTAssertFalse(enKeys.isEmpty, "EN table must not be empty")
        XCTAssertGreaterThan(enKeys.count, 100, "sanity: the tables should stay comprehensive")

        XCTAssertEqual(
            enKeys.subtracting(itKeys), [],
            "Keys present in EN but missing from IT (add Italian translations)"
        )
        XCTAssertEqual(
            itKeys.subtracting(enKeys), [],
            "Keys present in IT but missing from EN (add English source strings)"
        )
        XCTAssertEqual(L10n.allKeys, enKeys, "L10n.allKeys must equal the EN key set")
        XCTAssertEqual(L10n.table(for: .en).keys.sorted(), enKeys.sorted())
        XCTAssertEqual(L10n.table(for: .it).keys.sorted(), itKeys.sorted())
    }

    func testNoEmptyValues() {
        for (key, value) in english {
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty EN value for key '\(key)'"
            )
            XCTAssertNotEqual(value, key, "EN value for '\(key)' should be a human string, not the key")
        }
        for (key, value) in italian {
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty IT value for key '\(key)'"
            )
            XCTAssertNotEqual(value, key, "IT value for '\(key)' should be a human string, not the key")
        }
    }

    func testPlaceholderSignaturesMatchBetweenLanguages() {
        for key in L10n.allKeys.sorted() {
            let en = english[key] ?? ""
            let it = italian[key] ?? ""
            XCTAssertEqual(
                placeholderCounts(en), placeholderCounts(it),
                "Placeholder mismatch for '\(key)': EN=\(en) IT=\(it)"
            )
        }
    }

    func testPositionalPlaceholdersAreWellFormed() {
        for (language, table) in [(AppLanguage.en, english), (.it, italian)] {
            for (key, value) in table {
                let maxIndex = maxPositionalIndex(value)
                if maxIndex > 0 {
                    let signature = placeholderCounts(value)
                    let total = signature.values.reduce(0, +)
                    XCTAssertGreaterThanOrEqual(
                        total, maxIndex,
                        "\(language.shortCode) '\(key)' uses %\(maxIndex)$ but only declares \(total) conversion(s)"
                    )
                }
            }
        }
    }

    // MARK: - Source coverage (mirrors the external grep loop)

    func testEveryKeyUsedInDemoSourcesExistsInBothTables() throws {
        let used = try keysUsedInDemoSources()
        let totalKeysUsed = used.values.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(totalKeysUsed, 50, "sanity: expected the swept UI to use many keys")

        for (file, keys) in used.sorted(by: { $0.key < $1.key }) {
            let missingEN = keys.subtracting(english.keys)
            let missingIT = keys.subtracting(italian.keys)
            XCTAssertEqual(
                missingEN, [],
                "\(file): keys used by the UI but missing from the EN table: \(missingEN.sorted())"
            )
            XCTAssertEqual(
                missingIT, [],
                "\(file): keys used by the UI but missing from the IT table: \(missingIT.sorted())"
            )
        }
    }

    // MARK: - Existing UI reproduction (EN) / Italian review samples

    func testEnglishSamplesReproduceReceiptUI() {
        let samples: [String: String] = [
            "receipt.total": "TOTAL",
            "receipt.print": "PRINT",
            "receipt.sheets": "SHEETS",
            "receipt.thanks": "*** THANK YOU — DUPLEX DONE RIGHT ***",
            "receipt.drop.formats": "PDF · JPEG · HEIC · PNG · DOCX — lossless",
            "option.duplex": "Duplex",
            "option.color": "Color",
            "option.bw": "B&W",
            "option.quality.draft": "Draft · 180",
            "option.quality.normal": "Normal · 366",
            "option.quality.high": "High · 600",
            "more.title": "More options",
            "pages.title": "PAGES",
            "pages.apply": "Apply",
            "tools.title": "",
        ]
        var checked = samples
        checked.removeValue(forKey: "tools.title") // placeholder to document intent
        for (key, expected) in checked {
            XCTAssertEqual(english[key], expected, "EN value for '\(key)'")
        }
        XCTAssertEqual(english["pages.title"], "PAGES")
        XCTAssertEqual(english["pages.from"], "From")
        XCTAssertEqual(english["pages.to"], "To")
    }

    func testItalianSamples() {
        let samples: [String: String] = [
            "receipt.total": "TOTALE",
            "receipt.print": "STAMPA",
            "receipt.sheets": "FOGLI",
            "receipt.thanks": "*** GRAZIE — FRONTE-RETRO FATTO BENE ***",
            "option.duplex": "Fronte-retro",
            "option.color": "Colore",
            "option.bw": "Bianco e nero",
            "option.quality.draft": "Bozza · 180",
            "more.title": "Altre opzioni",
            "pages.title": "PAGINE",
            "pages.from": "Da",
            "pages.to": "A",
            "pages.increase": "Aumenta",
            "pages.decrease": "Riduci",
            "status.offline": "offline",
            "status.checkPrinter": "controlla stampante",
            "status.ready": "pronta",
            "flow.printing": "Stampa in corso…",
            "flow.printingFronts": "Stampa dei fronti…",
            "flow.printingBacks": "Stampa dei retri…",
            "flow.flip.title": "Capovolgi la risma",
            "common.cancel": "Annulla",
            "common.close": "Chiudi",
            "settings.title": "IMPOSTAZIONI",
            "settings.language": "LINGUA",
            "settings.quit": "ESCI DA FLIPSTACK",
            "menu.quit": "Esci da FlipStack",
            "toast.printed": "Stampato ✓",
            "toast.noPrinter": "Nessuna stampante selezionata",
            "error.noPrinter": "Nessuna stampante selezionata. Scegli una stampante prima di stampare.",
            "printer.loading": "Ricerca stampanti…",
            "calib.title": "Calibrazione",
            "calib.print": "Stampa foglio di calibrazione",
        ]
        for (key, expected) in samples {
            XCTAssertEqual(italian[key], expected, "IT value for '\(key)'")
        }
    }

    func testItalianFlowFragmentsCompose() {
        // The flow text is composed as: body + " " + edge + " " + body2.
        let body = italian["flow.flip.body"] ?? ""
        let edge = italian["option.edge.long"] ?? ""
        let body2 = italian["flow.flip.body2"] ?? ""
        XCTAssertEqual(body, "Capovolgi i fogli stampati sul bordo")
        XCTAssertEqual(edge, "lungo")
        XCTAssertEqual(body2, "e usa lo stesso vassoio, poi conferma.")
        let composed = "\(body) \(edge) \(body2)"
        XCTAssertEqual(composed, "Capovolgi i fogli stampati sul bordo lungo e usa lo stesso vassoio, poi conferma.")
    }

    func testItalianCalibrationInstructionsKeepThreeSteps() {
        let instructions = italian["calib.instructions"] ?? ""
        let lines = instructions.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "Calibration instructions must keep three lines")
        XCTAssertTrue(lines[0].hasPrefix("1."))
        XCTAssertTrue(lines[1].hasPrefix("2."))
        XCTAssertTrue(lines[2].hasPrefix("3."))
        XCTAssertTrue(instructions.contains("A4"))
    }

    func testLongStringsFitThePanelWidth() {
        // 320 pt panel minus 32 pt horizontal padding = 288 pt of usable text
        // width. The monospaced 10.5 pt receipt font advances ~6.3 pt/char.
        let risky = [
            "settings.version",
            "error.noPrinter",
            "printer.noneHint",
            "calib.instructions",
        ]
        for key in risky {
            let value = italian[key] ?? ""
            XCTAssertLessThanOrEqual(
                value.components(separatedBy: "\n").map(\.count).max() ?? 0,
                80,
                "'\(key)' has a line longer than 80 characters and risks truncation at 320 pt"
            )
        }
    }

    // MARK: - Runtime behavior

    func testLReturnsLocalizedValuesAndFallsBack() {
        XCTAssertEqual(T("receipt.total"), "TOTAL")

        L10n.withLanguage(.it) {
            XCTAssertEqual(T("receipt.total"), "TOTALE")
            XCTAssertEqual(T("flow.flip.title"), "Capovolgi la risma")
            XCTAssertEqual(T("status.unknown"), "sconosciuta")
            XCTAssertEqual(T("does.not.exist"), "does.not.exist")
        }

        XCTAssertEqual(L10n.current, .en, "withLanguage must restore the previous language")

        L10n.withLanguage(.en) {
            XCTAssertEqual(T("does.not.exist"), "does.not.exist")
            XCTAssertEqual(t("does.not.exist"), "does.not.exist")
            XCTAssertEqual(t("receipt.total"), "TOTAL")
        }

        XCTAssertEqual(T("definitely.missing.key"), "definitely.missing.key")
    }

    func testFormattingArguments() {
        L10n.withLanguage(.en) {
            XCTAssertEqual(T("receipt.printButton", "6 PAGES"), "PRINT 6 PAGES")
            XCTAssertEqual(T("toast.printerSelected", "CASA"), "Printer: CASA")
            XCTAssertEqual(T("header.queuedJobs", Units.jobs(2)), "· 2 jobs queued")
            XCTAssertEqual(T("pages.selectedCount", 6), "6 selected")
        }
        L10n.withLanguage(.it) {
            XCTAssertEqual(T("receipt.printButton", "6 PAGINE"), "STAMPA 6 PAGINE")
            XCTAssertEqual(T("toast.printerSelected", "CASA"), "Stampante: CASA")
            XCTAssertEqual(T("header.queuedJobs", Units.jobs(2)), "· 2 lavori in coda")
            XCTAssertEqual(T("pages.selectedCount", 6), "6 selezionate")
        }
    }

    func testUIStringFallbackBehavior() {
        L10n.withLanguage(.en) {
            XCTAssertEqual(L10n.uiString("receipt.total", "Fallback"), "TOTAL")
            XCTAssertEqual(L10n.uiString("not.a.real.key", "Fallback"), "Fallback")
        }
        L10n.withLanguage(.it) {
            XCTAssertEqual(L10n.uiString("receipt.total", "Fallback"), "TOTALE")
            XCTAssertEqual(L10n.uiString("not.a.real.key", "Fallback"), "Fallback")
        }
    }

    func testUIStringCoversKeysAddedBeforeTheTable() {
        // Regression guard: `uiText` must never leak a raw key into the UI.
        let fallbackOnly = L10n.uiString("some.future.key", "English copy")
        XCTAssertEqual(fallbackOnly, "English copy")
        XCTAssertNotEqual(fallbackOnly, "some.future.key")
    }

    // MARK: - Plural helpers

    func testEnglishPlurals() {
        L10n.withLanguage(.en) {
            XCTAssertEqual(Units.pages(0), "0 pages")
            XCTAssertEqual(Units.pages(1), "1 page")
            XCTAssertEqual(Units.pages(2), "2 pages")
            XCTAssertEqual(Units.sheets(1), "1 sheet")
            XCTAssertEqual(Units.sheets(3), "3 sheets")
            XCTAssertEqual(Units.copies(1), "1 copy")
            XCTAssertEqual(Units.copies(2), "2 copies")
            XCTAssertEqual(Units.jobs(1), "1 job")
            XCTAssertEqual(Units.jobs(5), "5 jobs")
            XCTAssertEqual(Units.pagesShort, "pg")
            XCTAssertEqual(L10n.pages(3), "3 pages")
            XCTAssertEqual(L10n.sheets(2), "2 sheets")
            XCTAssertEqual(L10n.copies(2), "2 copies")
            XCTAssertEqual(L10n.jobs(2), "2 jobs")
        }
    }

    func testItalianPlurals() {
        L10n.withLanguage(.it) {
            XCTAssertEqual(Units.pages(0), "0 pagine")
            XCTAssertEqual(Units.pages(1), "1 pagina")
            XCTAssertEqual(Units.pages(2), "2 pagine")
            XCTAssertEqual(Units.sheets(1), "1 foglio")
            XCTAssertEqual(Units.sheets(3), "3 fogli")
            XCTAssertEqual(Units.copies(1), "1 copia")
            XCTAssertEqual(Units.copies(2), "2 copie")
            XCTAssertEqual(Units.jobs(1), "1 lavoro")
            XCTAssertEqual(Units.jobs(5), "5 lavori")
            XCTAssertEqual(Units.pagesShort, "pagg.")
            XCTAssertEqual(L10n.pages(1), "1 pagina")
            XCTAssertEqual(L10n.sheets(2), "2 fogli")
        }
    }

    // MARK: - Language type

    func testAppLanguageMetadata() {
        XCTAssertEqual(AppLanguage.allCases, [.en, .it])
        XCTAssertEqual(AppLanguage.en.shortCode, "EN")
        XCTAssertEqual(AppLanguage.it.shortCode, "IT")
        XCTAssertEqual(AppLanguage.en.displayName, "English")
        XCTAssertEqual(AppLanguage.it.displayName, "Italiano")
        XCTAssertEqual(AppLanguage.en.id, "en")
        XCTAssertEqual(AppLanguage.it.id, "it")
        XCTAssertEqual(AppLanguage(rawValue: "it"), .it)
        XCTAssertNil(AppLanguage(rawValue: "es"), "ES is deferred to a later release")
    }

    func testTableLookupHelpers() {
        XCTAssertTrue(L10n.hasKey("receipt.total"))
        XCTAssertFalse(L10n.hasKey("no.such.key"))
        XCTAssertEqual(L10n.missingKeys(in: ["receipt.total", "no.such.key"], language: .en), ["no.such.key"])
        XCTAssertEqual(L10n.missingKeys(in: ["receipt.total"], language: .it), [])
        XCTAssertEqual(L10n.enTable["receipt.total"], "TOTAL")
        XCTAssertEqual(L10n.itTable["receipt.total"], "TOTALE")
    }

    // MARK: - Helpers

    private func placeholderCounts(_ value: String) -> [Character: Int] {
        var counts: [Character: Int] = ["@": 0, "d": 0]
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "%" else {
                index = value.index(after: index)
                continue
            }
            var cursor = value.index(after: index)
            while cursor < value.endIndex, value[cursor].isNumber {
                cursor = value.index(after: cursor)
            }
            if cursor < value.endIndex, value[cursor] == "$" {
                cursor = value.index(after: cursor)
            }
            if cursor < value.endIndex {
                let conversion = value[cursor]
                if conversion == "@" || conversion == "d" {
                    counts[conversion, default: 0] += 1
                }
            }
            index = value.index(after: index)
        }
        return counts
    }

    private func maxPositionalIndex(_ value: String) -> Int {
        var maximum = 0
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "%" else {
                index = value.index(after: index)
                continue
            }
            var cursor = value.index(after: index)
            var digits = ""
            while cursor < value.endIndex, value[cursor].isNumber {
                digits.append(value[cursor])
                cursor = value.index(after: cursor)
            }
            if !digits.isEmpty, cursor < value.endIndex, value[cursor] == "$" {
                maximum = max(maximum, Int(digits) ?? 0)
            }
            index = value.index(after: index)
        }
        return maximum
    }

    /// Extracts every key used as `T("…")`, `t("…")` or `uiText("…")` from the
    /// demo sources (Localization.swift excluded), grouped by file.
    private func keysUsedInDemoSources() throws -> [String: Set<String>] {
        let demoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FlipStackDemoTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Demo
        let sources = demoRoot.appendingPathComponent("Sources/FlipStackDemo", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Demo sources not found at \(sources.path) — coverage scan skipped")
        }

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Localization.swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result: [String: Set<String>] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let keys = Self.keys(inSource: source)
            if !keys.isEmpty { result[file.lastPathComponent] = keys }
        }
        return result
    }

    private static func keys(inSource source: String) -> Set<String> {
        var keys: Set<String> = []
        for needle in ["uiText(\"", "T(\"", "t(\""] {
            var searchStart = source.startIndex
            while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
                // Reject matches inside identifiers such as `format("` or `xl("`.
                if range.lowerBound > source.startIndex {
                    let previous = source[source.index(before: range.lowerBound)]
                    let isIdentifierCharacter = previous.isLetter || previous.isNumber || previous == "_"
                    if isIdentifierCharacter {
                        searchStart = source.index(after: range.lowerBound)
                        continue
                    }
                }
                let keyStart = range.upperBound
                if let close = source[keyStart...].firstIndex(of: "\"") {
                    let key = String(source[keyStart..<close])
                    if !key.isEmpty { keys.insert(key) }
                }
                searchStart = source.index(after: range.lowerBound)
            }
        }
        return keys
    }
}
