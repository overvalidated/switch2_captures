import AppKit
import CaptureTransfer
import SwiftUI

struct CaptureWindow: View {
    private enum Filter: String, CaseIterable {
        case all = "All"
        case screenshots = "Screenshots"
        case videos = "Videos"

        func includes(_ capture: Capture) -> Bool {
            switch self {
            case .all: true
            case .screenshots: capture.kind == .screenshot
            case .videos: capture.kind == .video
            }
        }
    }

    @Bindable var library: CaptureLibrary
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var confirmCameraRelease = false

    private var visible: [Capture] {
        library.captures.filter { capture in
            filter.includes(capture) && (search.isEmpty
                || capture.name.localizedStandardContains(search)
                || capture.album.localizedStandardContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch library.state {
            case .waiting:
                connectionInstructions
            case .loading:
                ProgressView("Reading the Switch 2 Album…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                album
            case .failed(let detail, let cameraBusy):
                ContentUnavailableView {
                    Label(cameraBusy ? "USB connection in use" : "Couldn’t read the Album",
                          systemImage: "exclamationmark.circle")
                } description: {
                    Text(detail)
                } actions: {
                    Button("Retry", action: library.reload)
                        .buttonStyle(.borderedProminent)
                    if cameraBusy {
                        Button("Release Camera Connection…") { confirmCameraRelease = true }
                    }
                }
            }
            if let summary = library.summary {
                Divider()
                HStack(spacing: 12) {
                    Text(summary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let destination = library.destination {
                        Button("Show in Finder") { NSWorkspace.shared.open(destination) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .tint(.accentColor)
        .alert("Release the macOS camera connection?", isPresented: $confirmCameraRelease) {
            Button("Cancel", role: .cancel) {}
            Button("Release and Retry", action: library.retryAfterReleasingCamera)
        } message: {
            Text("Switch Captures will briefly stop the camera service for your user account. This can interrupt other camera transfers.")
        }
    }

    private var connectionInstructions: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityHidden(true)
                Text("Connect your Switch 2")
                    .font(.largeTitle.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 14) {
                instruction(1, "On the console, open **System Settings → Data Management → Manage Screenshots and Videos**.")
                instruction(2, "Select **Copy to PC via USB Connection** and leave that screen open.")
                instruction(3, "Use a USB data cable to connect the console’s **bottom USB-C port** to your Mac. Choose **Allow** if macOS asks.")
            }
            .frame(maxWidth: 400)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number, format: .number)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var album: some View {
        let captures = visible
        let selected = captures.filter { library.selection.contains($0.id) }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Switch 2 Album", systemImage: "rectangle.stack")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Capture type", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Button(action: library.reload) {
                    Label("Reload Album", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Reload Album (⌘R)")
            }
            .disabled(library.isWorking)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            if captures.isEmpty {
                ContentUnavailableView(
                    library.captures.isEmpty ? "The Album is empty" : "No matching captures",
                    systemImage: library.captures.isEmpty ? "photo.on.rectangle" : "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(captures, selection: $library.selection) {
                    TableColumn("Filename") { capture in
                        Label(capture.name, systemImage: capture.kind == .video ? "film" : "photo")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(capture.name)
                    }
                    .width(min: 235, ideal: 400)
                    TableColumn("Game or folder", value: \.album)
                        .width(min: 125, ideal: 210)
                    TableColumn("Type") { capture in
                        Text(capture.kind.rawValue)
                    }
                    .width(min: 85, ideal: 90)
                    TableColumn("Size") { capture in
                        Text(capture.byteCount.map {
                            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                        } ?? "—")
                        .monospacedDigit()
                    }
                    .width(min: 68, ideal: 80)
                }
                .disabled(library.isWorking)
            }
            Divider()
            if let progress = library.progress {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: Double(progress.copied), total: Double(progress.total)) {
                            Text("Copying \(min(progress.copied + 1, progress.total)) of \(progress.total)")
                                .font(.callout.weight(.medium))
                        }
                        Text(progress.filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button(library.isStopping ? "Stopping…" : "Stop After This File", action: library.stopCopying)
                        .disabled(library.isStopping)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            } else {
                HStack {
                    if selected.isEmpty {
                        Text(captures.count == 1 ? "1 capture" : "\(captures.count) captures")
                    } else {
                        Text("\(selected.count) selected")
                    }
                    Spacer()
                    Button(selected.isEmpty ? "Copy All Shown…" : "Copy Selected…") {
                        library.chooseFolder(for: selected.isEmpty ? captures : selected)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(captures.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .searchable(text: $search, prompt: "Find captures")
        .onChange(of: filter) { library.selection.formIntersection(captures.map(\.id)) }
        .onChange(of: search) { library.selection.formIntersection(captures.map(\.id)) }
    }
}
