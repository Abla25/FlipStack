import FlipStackCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DocumentSection: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var artSize: CGFloat = 62
    @State private var isTargeted = false

    private var isBusy: Bool { model.isPreparingPrint }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                FlipEyebrow("Document")
                Spacer()
                if model.selectedDocument != nil {
                    Text("PDF")
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
                .padding(.bottom, 12)

            Text(isTargeted ? "Release to open" : "Drop a PDF to begin")
                .font(FlipType.displaySmall)
                .foregroundStyle(FlipColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("FlipStack prints the fronts, pauses while you flip the stack, then prints the backs.")
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
                    Text("Choose PDF")
                }
            }
            .buttonStyle(FlipSmallPrimaryButtonStyle())
            .padding(.top, 14)
            .accessibilityHint("Opens a file picker. Command-O works anywhere in the panel.")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                .fill(isTargeted ? FlipColor.coral.opacity(0.07) : FlipColor.tone)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        FlipColor.coral,
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
            } else {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        FlipColor.hairline,
                        style: StrokeStyle(lineWidth: 0.8, dash: [4, 4])
                    )
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    // MARK: Selected document

    private func documentSubtitle(_ document: SelectedDocument) -> String {
        let selection = model.pageSelectionInfo
        if selection.isValid,
           !selection.isAll,
           selection.pageCount > 0 {
            return "\(selection.summary) selected"
        }
        return document.formattedPageCount
    }

    private func selectedRow(_ document: SelectedDocument) -> some View {
        HStack(spacing: 11) {
            FlipFileGlyph(size: 43)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .font(.system(.callout, design: .default, weight: .medium))
                    .foregroundStyle(FlipColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(documentSubtitle(document))
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                    Circle()
                        .fill(FlipColor.tertiaryInk)
                        .frame(width: 2.5, height: 2.5)
                    Text("PDF")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Document, \(document.name), \(documentSubtitle(document))")

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                Button {
                    model.togglePreview()
                } label: {
                    if model.isPreparingPreview {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: model.isShowingPreview ? "eye.slash" : "eye")
                    }
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(isBusy)
                .help(model.isShowingPreview ? "Close preview" : "Preview print file")
                .accessibilityLabel(model.isShowingPreview ? "Close print preview" : "Preview print file")
                .accessibilityHint("Shows the pages that will be sent to the printer inside this panel.")

                Button {
                    model.chooseDocument()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(isBusy)
                .help("Replace PDF")
                .accessibilityLabel("Replace PDF")

                Button {
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.clearDocument()
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(isBusy)
                .help("Remove PDF")
                .accessibilityLabel("Remove PDF")
                .accessibilityHint("Clears the selected document.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                .fill(isTargeted ? FlipColor.coral.opacity(0.07) : FlipColor.tone)
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
        .overlay {
            if isTargeted {
                Text("Drop to replace")
                    .font(FlipType.footnoteStrong)
                    .foregroundStyle(FlipColor.onCoral)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(FlipColor.coral))
                    .transition(.opacity)
            }
        }
    }

    // MARK: Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
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

            guard let url else { return }
            Task { @MainActor in
                await model.acceptDocument(url: url)
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
