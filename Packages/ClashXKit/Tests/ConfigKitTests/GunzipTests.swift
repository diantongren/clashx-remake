import Foundation
import Testing
@testable import ConfigKit

@Suite("Gunzip")
struct GunzipTests {
    @Test func roundTripsThroughSystemGzip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appending(path: "payload.bin")
        var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024)
        for i in bytes.indices { bytes[i] = UInt8((i * 31) & 0xff) }
        try Data(bytes).write(to: original)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-n", original.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let gz = dir.appending(path: "payload.bin.gz")
        let out = dir.appending(path: "restored.bin")
        try Gunzip.decompress(from: gz, to: out)
        #expect(try Data(contentsOf: out) == Data(bytes))
    }

    @Test func rejectsNonGzip() {
        #expect(throws: GunzipError.self) {
            try Gunzip.gzipPayloadOffset(in: Data(repeating: 7, count: 64))
        }
    }
}
