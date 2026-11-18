import Foundation
import os

public final class ImportStop: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var requested: Bool { state.withLock { $0 } }

    public func request() {
        state.withLock { $0 = true }
    }
}

public struct ImportResult: Sendable {
    public let copied: Int
    public let errorMessage: String?
    public let needsReload: Bool
}

enum CaptureImporter {
    static func copy(
        _ captures: [Capture],
        into destination: URL,
        stop: ImportStop,
        progress: (Int, Capture) -> Void,
        download: (Capture, FileHandle) throws -> Void
    ) throws -> Int {
        let files = FileManager.default
        let staging = destination.appendingPathComponent(".switch-import-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        var copied = 0
        for capture in captures {
            if stop.requested { break }
            progress(copied, capture)
            let temporary = staging.appendingPathComponent("capture.part")
            do {
                try Data().write(to: temporary)
                let handle = try FileHandle(forWritingTo: temporary)
                defer { try? handle.close() }
                try download(capture, handle)
                try handle.close()
                if let date = capture.date {
                    try? files.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
                }
                try move(temporary, into: destination, as: capture.name)
                copied += 1
            } catch {
                throw ImportFailure(copied: copied, name: capture.name, underlyingError: error)
            }
        }
        return copied
    }

    private static func move(_ temporary: URL, into destination: URL, as name: String) throws {
        let files = FileManager.default
        let fileExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let filename = number == 1 ? name : "\(stem) (\(number)).\(fileExtension)"
            do {
                try files.moveItem(at: temporary, to: destination.appendingPathComponent(filename))
                return
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }
}

struct ImportFailure: LocalizedError {
    let copied: Int
    let name: String
    let underlyingError: any Error

    var errorDescription: String? {
        "Couldn’t copy \(name). \(underlyingError.localizedDescription)"
    }
}
