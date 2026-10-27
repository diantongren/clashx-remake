import CryptoKit
import Foundation
import HelperProtocol
import os

/// Owns the root proxy-core process. Exactly one core at a time; killed when we exit.
///
/// The client's copy of the core lives in a user-writable folder, so it is never executed directly:
/// the helper copies it into a root-owned directory, verifies the SHA-256 the client expects on
/// *that* copy, and runs the copy. A local attacker who swaps the user's file therefore only
/// breaks the hash check.
actor CoreSupervisor {
    private let logger = Logger(subsystem: "app.clashx.remake.helper", category: "core")
    private var process: Process?
    private var executablePath: String?
    private var lastExitCode: Int32?
    private var orphanCheck: Task<Void, Never>?

    private static let trustedDirectory = URL(fileURLWithPath: "/Library/Application Support/app.clashx.remake/core")

    init() {
        // If launchd kills us, take the core down with us.
        atexit_b { CoreSupervisor.killRecordedPid() }
    }

    func start(_ request: CoreLaunchRequest) async throws -> CoreStatus {
        orphanCheck?.cancel()
        await stop()
        Self.killRecordedPid()

        let workingDirectory = try Self.validatedWorkingDirectory(request.workingDirectory)
        let trusted = try Self.installTrustedCopy(from: request.executablePath, expectedSHA256: request.expectedSHA256)
        let handle = try Self.openLog(request.logFilePath, workingDirectory: workingDirectory)

        let process = Process()
        process.executableURL = trusted
        process.arguments = ["-d", workingDirectory.path, "-f", request.configFilePath]
        process.environment = ["SAFE_PATHS": request.safePaths.joined(separator: ":"),
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "HOME": workingDirectory.path]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] finished in
            try? handle.close()
            Task { await self?.processDidExit(finished) }
        }
        try process.run()
        self.process = process
        executablePath = trusted.path
        lastExitCode = nil
        Self.recordPid(process.processIdentifier)
        logger.notice("core started pid \(process.processIdentifier) from \(trusted.path)")
        return CoreStatus(isRunning: true, pid: process.processIdentifier, executablePath: trusted.path)
    }

    func stop() async {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        self.process = nil
        Self.recordPid(nil)
        logger.notice("core stopped")
    }

    func status() -> CoreStatus {
        if let process, process.isRunning {
            return CoreStatus(isRunning: true, pid: process.processIdentifier, executablePath: executablePath)
        }
        return CoreStatus(isRunning: false, lastExitCode: lastExitCode)
    }

    /// No clients are connected: if nobody reconnects within the grace period, stop the core so a
    /// crashed app never leaves a root proxy running.
    func scheduleOrphanCheck() {
        orphanCheck?.cancel()
        orphanCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            await self.stopIfStillOrphaned()
        }
    }

    private func stopIfStillOrphaned() async {
        logger.notice("no clients for 15s, stopping core")
        await stop()
    }

    private func processDidExit(_ finished: Process) {
        guard process === finished else { return }
        lastExitCode = finished.terminationStatus
        process = nil
        Self.recordPid(nil)
        logger.notice("core exited with status \(finished.terminationStatus)")
    }

    // MARK: - Trusted copy

    private static func installTrustedCopy(from sourcePath: String, expectedSHA256: String) throws -> URL {
        let expected = expectedSHA256.lowercased()
        guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw HelperProtocolError.remote("Invalid expected SHA-256")
        }
        let destination = trustedDirectory.appending(path: "mihomo-\(expected.prefix(16))")
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path), (try? sha256(ofRootOwnedFile: destination)) == expected {
            return destination
        }

        // Read the user's copy without following symlinks, require a regular file, hash it.
        let fd = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperProtocolError.remote("Cannot open core executable") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw HelperProtocolError.remote("Core executable is not a regular file")
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw HelperProtocolError.remote("Core executable hash mismatch (\(actual.prefix(12))…)")
        }

        try fm.createDirectory(at: trustedDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        for stale in (try? fm.contentsOfDirectory(at: trustedDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: stale)
        }
        try data.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: destination.path)
        guard try sha256(ofRootOwnedFile: destination) == expected else {
            try? fm.removeItem(at: destination)
            throw HelperProtocolError.remote("Trusted copy verification failed")
        }
        return destination
    }

    private static func sha256(ofRootOwnedFile url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperProtocolError.remote("Cannot open trusted copy") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0 else {
            close(fd)
            throw HelperProtocolError.remote("Trusted copy is not a root-owned regular file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Path validation

    private static let allowedRoots = ["/Users/", "/private/tmp/", "/tmp/", "/Volumes/"]

    /// The profile folder is user-chosen (mihomo writes its cache there) but must be a real
    /// directory in user territory, never a system location.
    private static func validatedWorkingDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard allowedRoots.contains(where: { url.path.hasPrefix($0) }) else {
            throw HelperProtocolError.remote("Working directory outside user territory: \(url.path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HelperProtocolError.remote("Working directory does not exist")
        }
        return url
    }

    /// The log file must live next to the profile folder or in a user Caches folder, must not be a
    /// symlink, and is only ever appended to.
    private static func openLog(_ path: String, workingDirectory: URL) throws -> FileHandle {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let inCaches = url.path.hasPrefix("/Users/") && url.pathComponents.contains("Caches")
        let inWorkingDirectory = url.path.hasPrefix(workingDirectory.path + "/")
        guard inCaches || inWorkingDirectory, url.pathExtension == "log" else {
            throw HelperProtocolError.remote("Refusing log path \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HelperProtocolError.remote("Cannot open log file") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw HelperProtocolError.remote("Log path is not a regular file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - PID bookkeeping across helper restarts

    private static let pidFile = "/var/run/app.clashx.remake.core.pid"

    private static func recordPid(_ pid: Int32?) {
        if let pid {
            try? String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: pidFile)
        }
    }

    nonisolated static func killRecordedPid() {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if path.hasPrefix(trustedDirectory.path) {
                kill(pid, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(atPath: pidFile)
    }
}
