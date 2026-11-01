import FlipStackCore
import SwiftUI
import UniformTypeIdentifiers

/// Step 1 of the workflow: drop any supported file (or pick one).
@MainActor
struct DocumentSection: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var artSize: CGFloat = 48
    @State private var isTargeted = false

    private var isBusy: Bool { model.isPreparingPrint }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            FlipSectionHeader("Document") {
                if model.isIngestingDocument {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(L("Converting file"))
                } else if let document = model.selectedDocument {
                    Text(document.formatTag)
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
            }

            if let document = model.selectedDocument {
                selectedRow(document)
            } else {
                dropZone
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .animation(FlipMotion.standard(reduceMotion), value: isTargeted)
    }

    // MARK: Empty drop target

    private var dropZone: some View {
        VStack(spacing: 0) {
            DropPageArt(isTargeted: isTargeted, size: artSize)
                .padding(.bottom, 8)

            Text(isTargeted ? L("Release to open") : L("Drop files to begin"))
                .font(FlipType.displaySmall)
                .foregroundStyle(FlipColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(L("PDFs, photos (JPEG, HEIC, PNG and more — full resolution), and Word or text documents."))
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
                .padding(.horizontal, 12)

            Button {
                model.chooseDocument()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("Choose files"))
                }
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .padding(.top, 10)
            .accessibilityHint(L("Opens a file picker for PDFs, photos, and documents. Command-O works anywhere in the panel."))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .fill(FlipColor.coral.opacity(0.07))
            } else {
                FlipGlassCard()
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(FlipColor.coral, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            } else {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(FlipColor.hairline, style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    // MARK: Selected document

    private func selectedRow(_ document: SelectedDocument) -> some View {
        HStack(spacing: 11) {
            FlipFileGlyph(size: 43)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .font(.system(.callout, design: .default, weight: .medium))
                    .foregroundStyle(FlipColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.pageSelectionInfo.isValid ? model.pageSelectionInfo.summary : document.formattedPageCount)
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .lineLimit(1)
                Text(document.pageSizeText)
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Document, \(document.name), \(document.pageSizeText)")

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                Button {
                    model.chooseDocument()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(isBusy)
                .help("Replace file")
                .accessibilityLabel(L("Replace file"))

                Button {
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.clearDocument()
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(isBusy)
                .help("Remove file")
                .accessibilityLabel(L("Remove file"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .fill(FlipColor.coral.opacity(0.07))
            } else {
                FlipGlassCard()
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(FlipColor.coral, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            } else {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
            }
        }
    }

    // MARK: Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let fileURL = item as? URL {
                    url = fileURL
                } else if let fileURL = item as? NSURL {
                    url = fileURL as URL
                } else {
                    url = nil
                }
                if let url { urls.append(url) }
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in
                await model.acceptDocuments(urls: urls)
            }
        }
        return true
    }
}

// MARK: - Art

private struct DropPageArt: View {
    let isTargeted: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .stroke(FlipColor.ink.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: size * 0.66, height: size * 0.84)
                .offset(x: -size * 0.1, y: size * 0.06)
                .rotationEffect(.degrees(-5))

            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.18), lineWidth: 0.7)
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: size * 0.075) {
                        Capsule().fill(FlipColor.coral)
                            .frame(width: size * 0.26, height: max(1.5, size * 0.038))
                        Capsule().fill(FlipColor.printLine.opacity(0.4))
                            .frame(width: size * 0.34, height: max(1, size * 0.03))
                        Capsule().fill(FlipColor.printLine.opacity(0.3))
                            .frame(width: size * 0.24, height: max(1, size * 0.03))
                    }
                    .padding(.leading, size * 0.13)
                    .padding(.top, size * 0.17)
                }
                .frame(width: size * 0.7, height: size * 0.9)
                .offset(x: size * 0.05, y: -size * 0.02)
                .rotationEffect(.degrees(isTargeted ? 2 : 0))

            Circle()
                .fill(FlipColor.coral)
                .frame(width: size * 0.34, height: size * 0.34)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.15, weight: .bold))
                        .foregroundStyle(FlipColor.onCoral)
                }
                .offset(x: size * 0.31, y: size * 0.33)
                .scaleEffect(isTargeted ? 1.08 : 1)
        }
        .frame(width: size, height: size)
        .animation(FlipMotion.quick(reduceMotion), value: isTargeted)
        .accessibilityHidden(true)
    }
}
