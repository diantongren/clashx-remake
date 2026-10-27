import Compression
import Foundation

public enum GunzipError: Error, LocalizedError, Sendable {
    case notGzip
    case truncated
    case decompressionFailed

    public var errorDescription: String? {
        switch self {
        case .notGzip: "The file is not in gzip format."
        case .truncated: "The gzip file is truncated."
        case .decompressionFailed: "Decompression failed."
        }
    }
}

/// Streams a `.gz` file to disk using libcompression (raw DEFLATE after the gzip header).
public enum Gunzip {
    public static func decompress(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let payloadStart = try gzipPayloadOffset(in: data)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw GunzipError.decompressionFailed
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try inflate(data.subdata(in: payloadStart..<(data.count - 8)), into: handle)
    }

    static func gzipPayloadOffset(in data: Data) throws -> Int {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b, data[data.startIndex + 2] == 8 else {
            throw GunzipError.notGzip
        }
        let flags = data[data.startIndex + 3]
        var offset = data.startIndex + 10
        func skipZeroTerminated() throws {
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            guard offset < data.endIndex else { throw GunzipError.truncated }
            offset += 1
        }
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= data.endIndex else { throw GunzipError.truncated }
            let length = Int(data[offset]) | Int(data[offset + 1]) << 8
            offset += 2 + length
        }
        if flags & 0x08 != 0 { try skipZeroTerminated() } // FNAME
        if flags & 0x10 != 0 { try skipZeroTerminated() } // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < data.endIndex - 8 else { throw GunzipError.truncated }
        return offset - data.startIndex
    }

    private static func inflate(_ input: Data, into handle: FileHandle) throws {
        let bufferSize = 1 << 20
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        var stream = compression_stream(dst_ptr: destinationBuffer, dst_size: bufferSize, src_ptr: destinationBuffer, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GunzipError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw GunzipError.truncated }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = destinationBuffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    try handle.write(contentsOf: Data(bytesNoCopy: destinationBuffer, count: produced, deallocator: .none))
                }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return
                default: throw GunzipError.decompressionFailed
                }
            }
        }
    }
}
