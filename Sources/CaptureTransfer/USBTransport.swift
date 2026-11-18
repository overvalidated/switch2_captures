import Foundation
import IOKit
import SwitchUSB

public enum ConnectionError: LocalizedError {
    case disconnected
    case busy
    case usb(operation: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "The Switch 2 disconnected. Reconnect it and open USB transfer mode again."
        case .busy:
            "Another app or the macOS camera service is using the USB connection. Quit any other transfer or camera apps, then retry."
        case .usb(let operation, let status):
            "Couldn’t \(operation) the Switch 2 over USB (\(String(format: "0x%08X", UInt32(bitPattern: status)))). Try reconnecting the USB cable."
        }
    }
}

final class USBTransport: PTPTransport {
    private let connection: OpaquePointer

    static func detect() -> UInt64? {
        let id = SwitchUSBFind()
        return id == 0 ? nil : id
    }

    init(id: UInt64) throws {
        var connection: OpaquePointer?
        let status = SwitchUSBOpen(id, &connection)
        if status == kIOReturnExclusiveAccess || status == kIOReturnBusy {
            throw ConnectionError.busy
        }
        try Self.check(status, operation: "open")
        guard let connection else { throw ConnectionError.disconnected }
        self.connection = connection
    }

    deinit {
        SwitchUSBClose(connection)
    }

    func send(_ data: Data) throws {
        var bytes = [UInt8](data)
        let status = SwitchUSBWrite(connection, &bytes, UInt32(bytes.count))
        try Self.check(status, operation: "send a command to")
    }

    func receive() throws -> Data {
        // A multiple of the USB bulk packet size, with bounded memory use for videos.
        var data = Data(count: 64 * 1024)
        var count = UInt32(data.count)
        let status = data.withUnsafeMutableBytes { buffer in
            SwitchUSBRead(connection, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), &count)
        }
        try Self.check(status, operation: "read from")
        data.count = Int(count)
        return data
    }

    static func releaseCameraService() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-TERM", "-x", "-u", String(geteuid()), "ptpcamerad"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private static func check(_ status: Int32, operation: String) throws {
        switch status {
        case kIOReturnSuccess: return
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnOffline:
            throw ConnectionError.disconnected
        default:
            throw ConnectionError.usb(operation: operation, status: status)
        }
    }
}
