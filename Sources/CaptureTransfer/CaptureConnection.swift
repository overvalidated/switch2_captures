import Foundation

public final class CaptureConnection: @unchecked Sendable {
    // The session and its device ID are accessed only on this serial queue.
    private let queue = DispatchQueue(label: "SwitchCaptures.USB", qos: .userInitiated)
    private var session: PTPSession?
    private var device: UInt64?

    public init() {}

    public static func detect() -> UInt64? { USBTransport.detect() }

    public func load(device: UInt64, releaseCameraService: Bool = false) async throws -> [Capture] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    if self.device != device || self.session?.isUsable != true {
                        self.closeSession()
                        if releaseCameraService {
                            try USBTransport.releaseCameraService()
                        }
                        self.session = try PTPSession(transport: USBTransport(id: device))
                        self.device = device
                    }
                    guard let session = self.session else { throw PTPError.sessionClosed }
                    do {
                        return try Album.load(from: session)
                    } catch {
                        self.closeSession()
                        throw error
                    }
                })
            }
        }
    }

    public func copy(
        _ captures: [Capture],
        device: UInt64,
        into destination: URL,
        stop: ImportStop,
        progress: @escaping @Sendable (Int, Capture) -> Void
    ) async -> ImportResult {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let session = self.session, self.device == device, session.isUsable else {
                    continuation.resume(returning: ImportResult(copied: 0, errorMessage: PTPError.sessionClosed.localizedDescription,
                                                                needsReload: true))
                    return
                }
                let result: ImportResult
                do {
                    let count = try CaptureImporter.copy(captures, into: destination, stop: stop, progress: progress) {
                        try session.download($0, to: $1)
                    }
                    result = ImportResult(copied: count, errorMessage: nil, needsReload: false)
                } catch {
                    let needsReload = !session.isUsable
                    if needsReload { self.closeSession() }
                    result = ImportResult(copied: (error as? ImportFailure)?.copied ?? 0,
                                          errorMessage: error.localizedDescription, needsReload: needsReload)
                }
                continuation.resume(returning: result)
            }
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeSession()
                continuation.resume()
            }
        }
    }

    private func closeSession() {
        session?.close()
        session = nil
        device = nil
    }
}
