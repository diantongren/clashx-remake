import Foundation
import HelperProtocol
import os

/// Owns the root proxy-core process. Exactly one core at a time; killed when we exit.
actor CoreSupervisor {
    private let logger = Logger(subsystem: "app.clashx.remake.helper", category: "core")
    private var process: Process?
    private var executablePath: String?
    private var lastExitCode: Int32?
    private var orphanCheck: Task<Void, Never>?

    init() {
        // If launchd kills us, take the core down with us.
        atexit_b { CoreSupervisor.killRecordedPid() }
    }

    func start(_ request: CoreLaunchRequest) async throws -> CoreStatus {
        orphanCheck?.cancel()
        await stop()
        Self.killRecordedPid()
        try Self.validate(executablePath: request.executablePath)

        let logURL = URL(fileURLWithPath: request.logFilePath)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = ["-d", request.workingDirectory, "-f", request.configFilePath]
        process.environment = ["SAFE_PATHS": request.safePaths.joined(separator: ":"),
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "HOME": request.workingDirectory]
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] finished in
            try? handle.close()
            Task { await self?.processDidExit(finished) }
        }
        try process.run()
        self.process = process
        executablePath = request.executablePath
        lastExitCode = nil
        Self.recordPid(process.processIdentifier)
        logger.notice("core started pid \(process.processIdentifier)")
        return CoreStatus(isRunning: true, pid: process.processIdentifier, executablePath: request.executablePath)
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

    // MARK: - Safety

    /// We are root; refuse to execute anything that is not a regular file owned by a real user
    /// *inside that user's Application Support*, so a compromised client cannot run arbitrary paths.
    private static func validate(executablePath: String) throws {
        let url = URL(fileURLWithPath: executablePath).standardizedFileURL
        let components = url.pathComponents
        guard components.count > 5, components[1] == "Users",
              components[3] == "Library", components[4] == "Application Support",
              components.contains(HelperConstants.appBundleIdentifier) else {
            throw HelperProtocolError.remote("Refusing to launch core outside Application Support: \(executablePath)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw HelperProtocolError.remote("Core executable missing or not executable")
        }
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
            if path.contains(HelperConstants.appBundleIdentifier) {
                kill(pid, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(atPath: pidFile)
    }
}
