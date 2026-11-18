import AppKit
import CaptureTransfer
import SwiftUI

@main
struct SwitchCapturesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: CaptureAppDelegate
    @State private var library = CaptureLibrary()

    var body: some Scene {
        Window("Switch Captures", id: "captures") {
            CaptureWindow(library: library)
                .frame(minWidth: 650, minHeight: 470)
                .onAppear { delegate.library = library }
                .task { await library.monitorUSB() }
        }
        .defaultSize(width: 860, height: 580)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Album", action: library.reload)
                    .keyboardShortcut("r")
                    .disabled(library.isWorking)
            }
        }
    }
}

@MainActor
final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    weak var library: CaptureLibrary?
    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await library.prepareToQuit()
            finishTermination(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard terminating else { return }
        terminating = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}

@MainActor
@Observable
final class CaptureLibrary {
    enum AlbumState {
        case waiting
        case loading
        case loaded
        case failed(String, cameraBusy: Bool)
    }

    struct CopyProgress {
        let id = UUID()
        let total: Int
        var copied = 0
        var filename = ""
    }

    private let connection = CaptureConnection()
    private var device: UInt64?
    private var stop: ImportStop?
    private var quitting = false
    private(set) var state = AlbumState.waiting
    private(set) var captures: [Capture] = []
    private(set) var progress: CopyProgress?
    private(set) var isStopping = false
    private(set) var summary: String?
    private(set) var destination: URL?
    var selection = Set<UInt32>()

    var isWorking: Bool {
        if quitting { return true }
        if case .loading = state { return true }
        return progress != nil
    }

    func monitorUSB() async {
        while !Task.isCancelled {
            if !isWorking {
                let current = CaptureConnection.detect()
                if current != device {
                    if let current {
                        await load(current)
                    } else {
                        await didDisconnect()
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func reload() {
        guard !isWorking else { return }
        guard let current = CaptureConnection.detect() else {
            Task { await didDisconnect() }
            return
        }
        Task { await load(current) }
    }

    func retryAfterReleasingCamera() {
        guard !isWorking, let current = CaptureConnection.detect() else { return }
        Task { await load(current, releaseCameraService: true) }
    }

    private func didDisconnect() async {
        device = nil
        captures = []
        selection = []
        state = .waiting
        await connection.disconnect()
    }

    private func load(_ current: UInt64, releaseCameraService: Bool = false) async {
        guard !isWorking else { return }
        if device != current {
            summary = nil
            destination = nil
        }
        device = current
        state = .loading
        captures = []
        selection = []
        do {
            captures = try await connection.load(device: current, releaseCameraService: releaseCameraService)
            state = .loaded
        } catch {
            let isBusy = (error as? ConnectionError).map { if case .busy = $0 { true } else { false } } ?? false
            state = .failed(error.localizedDescription, cameraBusy: isBusy)
        }
    }

    func chooseFolder(for captures: [Capture]) {
        guard !isWorking, !captures.isEmpty, let device else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to copy captures"
        panel.message = "The original files will be copied to this folder."
        panel.prompt = "Copy Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.copy(captures, device: device, into: folder)
        }
    }

    func stopCopying() {
        isStopping = true
        stop?.request()
    }

    func prepareToQuit() async {
        quitting = true
        stop?.request()
        await connection.disconnect()
    }

    private func copy(_ captures: [Capture], device: UInt64, into folder: URL) {
        guard !isWorking, self.device == device, CaptureConnection.detect() == device else { return }
        let copyProgress = CopyProgress(total: captures.count)
        let stop = ImportStop()
        self.stop = stop
        isStopping = false
        progress = copyProgress
        summary = nil
        destination = nil
        Task {
            let result = await connection.copy(captures, device: device, into: folder, stop: stop) { [weak self] count, capture in
                Task { @MainActor in
                    guard let self, self.progress?.id == copyProgress.id else { return }
                    self.progress?.copied = count
                    self.progress?.filename = capture.name
                }
            }
            progress = nil
            self.stop = nil
            isStopping = false
            let countText = result.copied == 1 ? "Copied 1 file." : "Copied \(result.copied) files."
            if let error = result.errorMessage {
                if result.needsReload {
                    summary = result.copied > 0 ? countText : nil
                    state = .failed(error, cameraBusy: false)
                    self.captures = []
                    selection = []
                } else {
                    summary = "\(countText) \(error)"
                }
            } else {
                summary = result.copied < captures.count ? "\(countText) Import stopped." : countText
                selection = []
            }
            if result.copied > 0 { destination = folder }
        }
    }
}
