import Foundation

/// Translates a decoded IPP response into the app's frozen status model.
enum IPPStatusMapper {
    static func status(
        from response: IPPResponse,
        printer: Printer,
        snmpSupplies: [SupplyLevel] = []
    ) -> PrinterStatus {
        guard response.isSuccess else {
            let note = response.statusNote ?? "Live status is not available right now."
            return fallback(for: printer, note: note, snmpSupplies: snmpSupplies)
        }

        let state = state(from: response.values(named: "printer-state")) ?? printer.state
        let reasons = reasons(
            from: response.values(named: "printer-state-reasons"),
            fallback: printer.stateReasons
        )
        let ippSupplies = supplies(from: response)

        if !ippSupplies.isEmpty {
            return PrinterStatus(
                printerID: printer.id,
                state: state,
                stateReasons: reasons,
                supplies: ippSupplies,
                origin: .ipp
            )
        }

        if !snmpSupplies.isEmpty {
            return PrinterStatus(
                printerID: printer.id,
                state: state,
                stateReasons: reasons,
                supplies: snmpSupplies,
                origin: .snmp,
                note: "Supply levels read from SNMP."
            )
        }

        return PrinterStatus(
            printerID: printer.id,
            state: state,
            stateReasons: reasons,
            origin: .ipp,
            note: "No supply levels reported by IPP"
        )
    }

    static func fallback(
        for printer: Printer,
        note: String,
        snmpSupplies: [SupplyLevel] = []
    ) -> PrinterStatus {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseNote = trimmed.isEmpty ? "Live status is not available right now." : trimmed

        if !snmpSupplies.isEmpty {
            return PrinterStatus(
                printerID: printer.id,
                state: printer.state,
                stateReasons: printer.stateReasons,
                supplies: snmpSupplies,
                origin: .snmp,
                note: "\(baseNote) Supply levels from SNMP."
            )
        }

        return unavailable(for: printer, note: baseNote)
    }

    static func unavailable(for printer: Printer, note: String) -> PrinterStatus {
        PrinterStatus(
            printerID: printer.id,
            state: printer.state,
            stateReasons: printer.stateReasons,
            origin: .unavailable,
            note: note
        )
    }

    static func state(from values: [IPPValue]) -> PrinterState? {
        for value in values {
            guard let raw = value.intValue else { continue }
            switch raw {
            case 3: return .idle
            case 4: return .processing
            case 5: return .stopped
            default: continue
            }
        }
        return nil
    }

    static func reasons(from values: [IPPValue], fallback: [String]) -> [String] {
        // No attribute at all: preserve what CUPS/queue discovery last knew.
        guard !values.isEmpty else { return fallback }

        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            guard let raw = value.stringValue else { continue }
            for fragment in raw.split(separator: ",", omittingEmptySubsequences: false) {
                let reason = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reason.isEmpty, reason.lowercased() != "none" else { continue }
                if seen.insert(reason).inserted {
                    result.append(reason)
                }
            }
        }
        return result
    }

    // MARK: - Supply extraction

    static func supplies(from response: IPPResponse) -> [SupplyLevel] {
        let collections = collectionSupplies(from: response)
        if !collections.isEmpty { return collections }

        let legacy = legacyArraySupplies(from: response)
        if !legacy.isEmpty { return legacy }

        return printerSupplyStrings(from: response)
    }

    private static func collectionSupplies(from response: IPPResponse) -> [SupplyLevel] {
        var supplies: [SupplyLevel] = []
        var usedIDs = Set<String>()

        for (index, value) in response.values(named: "printer-marker-supplies").enumerated() {
            guard let members = value.collectionValue else { continue }
            let fields = memberFields(members)

            let name = firstString(in: fields, names: [
                "marker-name", "marker-description", "printer-marker-supply", "name", "description"
            ]) ?? "Supply \(index + 1)"
            let types = strings(in: fields, name: "marker-types")
            let colors = strings(in: fields, name: "marker-colors")
            let levels = integers(in: fields, name: "marker-levels")
            let highLevels = integers(in: fields, name: "marker-high-levels")

            let color = IPPSupplyNormalizer.colorName(fromToken: colors.first)
                ?? IPPSupplyNormalizer.colorName(inText: name)
            let kind = IPPSupplyNormalizer.kind(typeTokens: types, name: name, color: color)
            let percent = IPPSupplyNormalizer.normalizedPercent(
                level: levels.first,
                capacity: highLevels.first
            )

            supplies.append(
                SupplyFactory.make(
                    prefix: "ipp",
                    name: name,
                    kind: kind,
                    colorName: color,
                    levelPercent: percent,
                    index: index,
                    usedIDs: &usedIDs
                )
            )
        }

        return supplies
    }

    private static func legacyArraySupplies(from response: IPPResponse) -> [SupplyLevel] {
        let names = stringValues(response.values(named: "marker-names"))
        let colors = stringValues(response.values(named: "marker-colors"))
        let types = stringValues(response.values(named: "marker-types"))
        let levels = integerValues(response.values(named: "marker-levels"))
        let highLevels = integerValues(response.values(named: "marker-high-levels"))
        // The low-level array is advisory and does not change the displayed
        // current/capacity percentage, but it is consumed for completeness.
        _ = integerValues(response.values(named: "marker-low-levels"))

        let count = max(names.count, colors.count, types.count, levels.count, highLevels.count)
        guard count > 0 else { return [] }

        var supplies: [SupplyLevel] = []
        var usedIDs = Set<String>()

        for index in 0..<count {
            let name = value(at: index, in: names) ?? "Supply \(index + 1)"
            let color = IPPSupplyNormalizer.colorName(fromToken: value(at: index, in: colors))
                ?? IPPSupplyNormalizer.colorName(inText: name)
            let type = value(at: index, in: types)
            let kind = IPPSupplyNormalizer.kind(
                typeTokens: type.map { [$0] } ?? [],
                name: name,
                color: color
            )
            let percent = IPPSupplyNormalizer.normalizedPercent(
                level: value(at: index, in: levels),
                capacity: value(at: index, in: highLevels)
            )

            supplies.append(
                SupplyFactory.make(
                    prefix: "ipp",
                    name: name,
                    kind: kind,
                    colorName: color,
                    levelPercent: percent,
                    index: index,
                    usedIDs: &usedIDs
                )
            )
        }

        return supplies
    }

    private static func printerSupplyStrings(from response: IPPResponse) -> [SupplyLevel] {
        let rawSupplies = stringValues(response.values(named: "printer-supply"))
        guard !rawSupplies.isEmpty else { return [] }
        let descriptions = stringValues(response.values(named: "printer-supply-description"))

        var supplies: [SupplyLevel] = []
        var usedIDs = Set<String>()

        for (index, raw) in rawSupplies.enumerated() {
            let fields = parseKeyValueString(raw)
            guard !fields.isEmpty else { continue }

            let name = fields["description"]
                ?? fields["name"]
                ?? value(at: index, in: descriptions)
                ?? "Supply \(index + 1)"
            let color = IPPSupplyNormalizer.colorName(fromToken: fields["color"])
                ?? IPPSupplyNormalizer.colorName(inText: name)
            let type = fields["type"]
            let kind = IPPSupplyNormalizer.kind(
                typeTokens: type.map { [$0] } ?? [],
                name: name,
                color: color
            )
            let percent = IPPSupplyNormalizer.normalizedPercent(
                level: fields["level"].flatMap(Int.init),
                capacity: fields["maxcapacity"].flatMap(Int.init) ?? fields["capacity"].flatMap(Int.init)
            )

            supplies.append(
                SupplyFactory.make(
                    prefix: "ipp",
                    name: name,
                    kind: kind,
                    colorName: color,
                    levelPercent: percent,
                    index: index,
                    usedIDs: &usedIDs
                )
            )
        }

        return supplies
    }

    private static func parseKeyValueString(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            let value = part[part.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func memberFields(_ members: [IPPCollectionMember]) -> [String: [IPPValue]] {
        var fields: [String: [IPPValue]] = [:]
        for member in members {
            let key = member.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty else { continue }
            fields[key, default: []].append(member.value)
        }
        return fields
    }

    private static func firstString(in fields: [String: [IPPValue]], names: [String]) -> String? {
        for name in names {
            for value in fields[name] ?? [] {
                if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private static func strings(in fields: [String: [IPPValue]], name: String) -> [String] {
        stringValues(fields[name] ?? [])
    }

    private static func integers(in fields: [String: [IPPValue]], name: String) -> [Int] {
        integerValues(fields[name] ?? [])
    }

    private static func stringValues(_ values: [IPPValue]) -> [String] {
        values.compactMap { value in
            guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else {
                return nil
            }
            return string
        }
    }

    private static func integerValues(_ values: [IPPValue]) -> [Int] {
        values.compactMap(\.intValue)
    }

    private static func value<T>(at index: Int, in values: [T]) -> T? {
        guard index >= 0, index < values.count else { return nil }
        return values[index]
    }
}
