import Foundation

public struct Capture: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case screenshot = "Screenshot"
        case video = "Video"
    }

    public let id: UInt32
    public let name: String
    public let album: String
    public let kind: Kind
    public let byteCount: Int?
    public let date: Date?
}

enum Album {
    private struct Object {
        let parent: UInt32
        let name: String
        let format: UInt16
        let byteCount: Int?
        let captureDate: String

        var isFolder: Bool { format == 0x3001 }

        init(data: Data) throws {
            var reader = PTPReader(data)
            _ = try reader.integer(UInt32.self) // Storage ID
            format = try reader.integer(UInt16.self)
            _ = try reader.integer(UInt16.self) // Protection status
            let size = try reader.integer(UInt32.self)
            byteCount = size == 0 || size == UInt32.max ? nil : Int(size)
            _ = try reader.take(26) // Thumbnail and image dimensions, bit depth
            parent = try reader.integer(UInt32.self)
            _ = try reader.take(10) // Association type, description, sequence number
            name = try reader.string()
            captureDate = reader.remaining > 0 ? try reader.string() : ""
        }
    }

    static func load(from session: PTPSession) throws -> [Capture] {
        var storageIDs = PTPReader(try session.data(.getStorageIDs, limit: 4096))
        var objects = [UInt32: Object]()
        for storage in try storageIDs.uint32Array() {
            var pending: [UInt32] = [UInt32.max] // Root association
            var visited = Set<UInt32>()
            while let parent = pending.popLast() {
                var handles = PTPReader(try session.data(.getObjectHandles,
                    parameters: [storage, 0, parent], limit: 1024 * 1024))
                for handle in try handles.uint32Array() where visited.insert(handle).inserted {
                    do {
                        let object = try Object(data: session.data(.getObjectInfo, parameters: [handle], limit: 4096))
                        objects[handle] = object
                        if object.isFolder { pending.append(handle) }
                    } catch PTPError.response(_, 0x2009) {
                        // The object was removed since its handle was listed.
                        continue
                    }
                }
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return objects.compactMap { handle, object -> Capture? in
            guard !object.isFolder, !object.name.contains("/"), !object.name.utf8.contains(0) else { return nil }
            let kind: Capture.Kind
            switch (object.name as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg", "png":
                kind = .screenshot
            case "mp4":
                kind = .video
            default:
                return nil
            }

            var folders = [String]()
            var visited = Set<UInt32>()
            var parent = object.parent
            while let folder = objects[parent], folder.isFolder, visited.insert(parent).inserted {
                folders.append(folder.name)
                parent = folder.parent
            }
            let album = folders.isEmpty ? "Album" : folders.reversed().joined(separator: " / ")
            let date = dateFormatter.date(from: object.captureDate)
            return Capture(id: handle, name: object.name, album: album, kind: kind,
                           byteCount: object.byteCount, date: date)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedDescending
        }
    }
}
