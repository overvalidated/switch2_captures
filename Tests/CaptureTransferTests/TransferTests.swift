import Foundation
import Testing
@testable import CaptureTransfer

@Test func listsScreenshotsAndVideosInNestedAlbums() throws {
    let transport = ScriptedUSB([
        response(0),
        payload(.getStorageIDs, 1, integers(1, 0x00320001)),
        response(1),
        payload(.getObjectHandles, 2, integers(1, 100)),
        response(2),
        payload(.getObjectInfo, 3, objectInfo("ひみつのゲーム", format: 0x3001, size: 0, parent: 0)),
        response(3),
        payload(.getObjectHandles, 4, integers(2, 101, 102)),
        response(4),
        payload(.getObjectInfo, 5, objectInfo("capture.jpg", format: 0x3801, size: 45, parent: 100)),
        response(5),
        payload(.getObjectInfo, 6, objectInfo("clip.mp4", format: 0xB982, size: 80, parent: 100)),
        response(6),
        response(7)
    ])
    let session = try PTPSession(transport: transport)
    let captures = try Album.load(from: session)
    session.close()

    #expect(captures.map(\.name) == ["clip.mp4", "capture.jpg"])
    #expect(captures.map(\.kind) == [.video, .screenshot])
    #expect(captures.map(\.album) == ["ひみつのゲーム", "ひみつのゲーム"])
    #expect(transport.commands[2].suffix(12) == integers(0x00320001, 0, UInt32.max))
    #expect(transport.commands[4].suffix(12) == integers(0x00320001, 0, 100))
    #expect(transport.chunks.isEmpty)
}

@Test func streamsSplitDataAndHandlesZeroLengthUSBPacket() throws {
    let bytes = Data(repeating: 0x4d, count: 128 * 1024)
    let dataContainer = payload(.getObject, 1, bytes)
    let transport = ScriptedUSB([
        response(0),
        dataContainer.prefix(12),
        bytes.prefix(64 * 1024),
        bytes.suffix(64 * 1024),
        Data(),
        Data(),
        response(1),
        response(2)
    ])
    let session = try PTPSession(transport: transport)
    try withTemporaryFolder { folder in
        let capture = sampleCapture(1, "clip.mp4", byteCount: bytes.count)
        let count = try CaptureImporter.copy([capture], into: folder, stop: ImportStop(), progress: { _, _ in }) {
            try session.download($0, to: $1)
        }
        #expect(count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(capture.name)) == bytes)
    }
    session.close()
    #expect(transport.chunks.isEmpty)
}

@Test func disconnectKeepsCompletedFilesAndCleansPartialData() throws {
    let bytes = Data([1, 2, 3])
    let truncated = payload(.getObject, 2, bytes).dropLast()
    let transport = ScriptedUSB([
        response(0),
        payload(.getObject, 1, bytes) + response(1),
        truncated
    ])
    let session = try PTPSession(transport: transport)
    try withTemporaryFolder { folder in
        let first = sampleCapture(1, "capture.jpg", byteCount: bytes.count)
        let second = sampleCapture(2, "clip.mp4", byteCount: bytes.count)
        var result: ImportFailure?
        do {
            _ = try CaptureImporter.copy([first, second], into: folder, stop: ImportStop(), progress: { _, _ in }) {
                try session.download($0, to: $1)
            }
        } catch let failure as ImportFailure {
            result = failure
        }
        #expect(result?.copied == 1)
        #expect(result?.name == second.name)
        #expect(!session.isUsable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [first.name])
        #expect(try Data(contentsOf: folder.appendingPathComponent(first.name)) == bytes)
    }
}

@Test func keepsExistingFilesAndStopsBetweenCopies() throws {
    try withTemporaryFolder { folder in
        let bytes = Data([5, 4, 3])
        let capture = sampleCapture(1, "capture.jpg", byteCount: bytes.count)
        let existing = folder.appendingPathComponent(capture.name)
        try Data([0]).write(to: existing)
        let stop = ImportStop()
        let count = try CaptureImporter.copy([capture, capture], into: folder, stop: stop, progress: { _, _ in }) { _, handle in
            try handle.write(contentsOf: bytes)
            stop.request()
        }
        #expect(count == 1)
        #expect(try Data(contentsOf: existing) == Data([0]))
        #expect(try Data(contentsOf: folder.appendingPathComponent("capture (2).jpg")) == bytes)
    }
}

private final class ScriptedUSB: PTPTransport {
    var chunks: [Data]
    var commands = [Data]()

    init(_ chunks: [Data]) {
        self.chunks = chunks
    }

    func send(_ data: Data) throws {
        commands.append(data)
    }

    func receive() throws -> Data {
        guard !chunks.isEmpty else { throw ConnectionError.disconnected }
        return chunks.removeFirst()
    }
}

private func response(_ transaction: UInt32) -> Data {
    integers(12) + littleEndian(UInt16(3)) + littleEndian(UInt16(0x2001)) + integers(transaction)
}

private func payload(_ operation: PTPOperation, _ transaction: UInt32, _ bytes: Data) -> Data {
    integers(UInt32(12 + bytes.count)) + littleEndian(UInt16(2)) + littleEndian(operation.rawValue)
        + integers(transaction) + bytes
}

private func objectInfo(_ name: String, format: UInt16, size: UInt32, parent: UInt32) -> Data {
    let filename = Array(name.utf16) + [0]
    return integers(0x00320001) + littleEndian(format) + littleEndian(UInt16(0)) + integers(size)
        + Data(count: 26) + integers(parent) + Data(count: 10)
        + Data([UInt8(filename.count)]) + filename.reduce(into: Data()) { $0.append(littleEndian($1)) }
        + Data(count: 3)
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var bytes = value.littleEndian
    return withUnsafeBytes(of: &bytes) { Data($0) }
}

private func integers(_ values: UInt32...) -> Data {
    values.reduce(into: Data()) { $0.append(littleEndian($1)) }
}

private func sampleCapture(_ id: UInt32, _ name: String, byteCount: Int) -> Capture {
    Capture(id: id, name: name, album: "Album", kind: name.hasSuffix(".mp4") ? .video : .screenshot,
            byteCount: byteCount, date: nil)
}

private func withTemporaryFolder(_ run: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    try run(folder)
}
