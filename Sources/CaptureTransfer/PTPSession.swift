import Foundation

protocol PTPTransport: AnyObject {
    func send(_ data: Data) throws
    func receive() throws -> Data
}

enum PTPError: LocalizedError {
    case invalidData(String)
    case response(operation: UInt16, code: UInt16)
    case sessionClosed
    case staleSession

    var errorDescription: String? {
        switch self {
        case .invalidData(let detail):
            "The Switch 2 returned an unexpected reply. \(detail)"
        case .response(let operation, let code):
            String(format: "The Switch 2 rejected command 0x%04X (response 0x%04X).", operation, code)
        case .sessionClosed:
            "The USB session ended. Reload the Album to reconnect."
        case .staleSession:
            "The Switch 2 still has a previous USB session open. Unplug the cable, reopen Copy to PC via USB Connection on the console, and reconnect."
        }
    }
}

enum PTPOperation: UInt16 {
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
}

struct PTPReader {
    private var data: Data

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count }

    mutating func take(_ count: Int) throws -> Data {
        guard count <= data.count else {
            throw PTPError.invalidData("A data field was cut short.")
        }
        let result = data.prefix(count)
        data.removeFirst(count)
        return result
    }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    mutating func string() throws -> String {
        let count = Int(try integer(UInt8.self))
        guard count > 0 else { return "" }
        let bytes = try take(count * 2)
        guard bytes.suffix(2).allSatisfy({ $0 == 0 }) else {
            throw PTPError.invalidData("A filename or date was unterminated.")
        }
        return String(decoding: bytes.dropLast(2).withUnsafeBytes { buffer in
            (0..<(count - 1)).map { index in
                UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
            }
        }, as: UTF16.self)
    }

    mutating func uint32Array() throws -> [UInt32] {
        let count = Int(try integer(UInt32.self))
        guard count == remaining / 4, remaining.isMultiple(of: 4) else {
            throw PTPError.invalidData("An object or storage list had the wrong length.")
        }
        return try (0..<count).map { _ in try integer(UInt32.self) }
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

final class PTPSession {
    private struct Header {
        let payloadLength: Int
        let type: UInt16
        let code: UInt16
    }

    private let transport: PTPTransport
    private var buffer = Data()
    private var nextTransaction: UInt32 = 0
    private(set) var isUsable = true

    init(transport: PTPTransport) throws {
        self.transport = transport
        do {
            try transact(.openSession, parameters: [1])
        } catch PTPError.response(_, 0x201E) {
            // A previous client may have left a session open after losing USB access.
            do {
                try transact(.closeSession)
                nextTransaction = 0
                try transact(.openSession, parameters: [1])
            } catch PTPError.response {
                throw PTPError.staleSession
            }
        }
    }

    func close() {
        guard isUsable else { return }
        try? transact(.closeSession)
        isUsable = false
    }

    func data(_ operation: PTPOperation, parameters: [UInt32] = [], limit: Int) throws -> Data {
        var result = Data()
        try transact(operation, parameters: parameters, receive: { header, chunk in
            guard header.payloadLength <= limit else {
                throw PTPError.invalidData("A catalog reply was too large.")
            }
            result.append(chunk)
        })
        return result
    }

    func download(_ capture: Capture, to file: FileHandle) throws {
        try transact(.getObject, parameters: [capture.id], receive: { header, chunk in
            if header.payloadLength == 0 || capture.byteCount.map({ $0 != header.payloadLength }) == true {
                throw PTPError.invalidData("The file size changed. Reload the Album and try again.")
            }
            try file.write(contentsOf: chunk)
        })
    }

    private func transact(
        _ operation: PTPOperation,
        parameters: [UInt32] = [],
        receive: ((Header, Data) throws -> Void)? = nil
    ) throws {
        guard isUsable else { throw PTPError.sessionClosed }
        let transaction = nextTransaction
        nextTransaction &+= 1
        var command = Data()
        command.appendInteger(UInt32(12 + parameters.count * 4))
        command.appendInteger(UInt16(1))
        command.appendInteger(operation.rawValue)
        command.appendInteger(transaction)
        for value in parameters {
            command.appendInteger(value)
        }

        let response: Header
        let receivedData: Bool
        do {
            try transport.send(command)
            var header = try readHeader(transaction: transaction)
            receivedData = header.type == 2
            if receivedData {
                guard let receive, header.code == operation.rawValue else {
                    throw PTPError.invalidData("The data did not match the requested command.")
                }
                var remaining = header.payloadLength
                if remaining == 0 {
                    try receive(header, Data())
                }
                while remaining > 0 {
                    try fillBuffer()
                    let count = min(buffer.count, remaining)
                    try receive(header, consume(count))
                    remaining -= count
                }
                header = try readHeader(transaction: transaction)
            }
            guard header.type == 3, header.payloadLength <= 20, header.payloadLength.isMultiple(of: 4) else {
                throw PTPError.invalidData("The command response was malformed.")
            }
            _ = try readExactly(header.payloadLength)
            response = header
        } catch {
            isUsable = false
            throw error
        }

        guard response.code == 0x2001 else {
            throw PTPError.response(operation: operation.rawValue, code: response.code)
        }
        if receive != nil && !receivedData {
            throw PTPError.invalidData("The command response did not include its data.")
        }
    }

    private func readHeader(transaction: UInt32) throws -> Header {
        var reader = PTPReader(try readExactly(12))
        let length = Int(try reader.integer(UInt32.self))
        let type = try reader.integer(UInt16.self)
        let code = try reader.integer(UInt16.self)
        let receivedTransaction = try reader.integer(UInt32.self)
        guard length >= 12, length < Int(UInt32.max), receivedTransaction == transaction else {
            throw PTPError.invalidData("The USB packet length or transaction number was invalid.")
        }
        return Header(payloadLength: length - 12, type: type, code: code)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            try fillBuffer()
            bytes.append(consume(min(buffer.count, count - bytes.count)))
        }
        return bytes
    }

    private func consume(_ count: Int) -> Data {
        let bytes = buffer.prefix(count)
        buffer.removeFirst(count)
        return bytes
    }

    private func fillBuffer() throws {
        guard buffer.isEmpty else { return }
        // A USB transfer that ends on a full packet can be followed by a zero-length packet.
        for _ in 0..<3 {
            buffer = try transport.receive()
            if !buffer.isEmpty { return }
        }
        throw PTPError.invalidData("The USB transfer ended before the complete reply arrived.")
    }
}
