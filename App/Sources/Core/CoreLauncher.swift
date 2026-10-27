import Foundation
import HelperProtocol

/// Something that can spawn and stop the proxy core.
protocol CoreLauncher: AnyObject {
    var launchMode: LaunchMode { get }
    /// Spawns the core and returns as soon as the process exists; readiness is the caller's job.
    func launch(_ request: CoreLaunchRequest) async throws -> CoreStatus
    func status() async -> CoreStatus
    func terminate() async
}

// MARK: - User space

/// Runs the core as the current user. No TUN, no system proxy changes, but zero setup.
final class UserSpaceCoreLauncher: CoreLauncher {
    let launchMode: LaunchMode = .userSpace
    private var process: Process?
    private var lastExitCode: Int32?
    private let pidFile: URL

    init(pidFile: URL) {
        self.pidFile = pidFile
    }

    func launch(_ request: CoreLaunchRequest) async throws -> CoreStatus {
        await terminate()
        killOrphan(matching: request.executablePath)

        let logURL = URL(fileURLWithPath: request.logFilePath)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = ["-d", request.workingDirectory, "-f", request.configFilePath]
        var environment = ProcessInfo.processInfo.environment
        environment["SAFE_PATHS"] = request.safePaths.joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            try? logHandle.close()
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.lastExitCode = status
                self.process = nil
                try? FileManager.default.removeItem(at: self.pidFile)
                Log.core.notice("user-space core exited with status \(status)")
            }
        }
        try process.run()
        self.process = process
        lastExitCode = nil
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        Log.core.notice("user-space core started pid \(process.processIdentifier)")
        return CoreStatus(isRunning: true, pid: process.processIdentifier, executablePath: request.executablePath)
    }

    func status() async -> CoreStatus {
        if let process, process.isRunning {
            return CoreStatus(isRunning: true, pid: process.processIdentifier, executablePath: process.executableURL?.path)
        }
        return CoreStatus(isRunning: false, lastExitCode: lastExitCode)
    }

    func terminate() async {
        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<30 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        self.process = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// A previous app instance that crashed may have left its core behind; reap it.
    private func killOrphan(matching executablePath: String) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0, String(cString: buffer) == executablePath {
            Log.core.warning("killing orphaned core pid \(pid)")
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }
}

// MARK: - Privileged

/// Delegates to the SMAppService daemon so the core runs as root.
final class PrivilegedCoreLauncher: CoreLauncher {
    let launchMode: LaunchMode = .privileged
    private let helper: HelperClient

    init(helper: HelperClient) {
        self.helper = helper
    }

    func launch(_ request: CoreLaunchRequest) async throws -> CoreStatus {
        try await helper.request(HelperMessages.StartCore(request: request))
    }

    func status() async -> CoreStatus {
        (try? await helper.request(HelperMessages.GetCoreStatus())) ?? CoreStatus(isRunning: false)
    }

    func terminate() async {
        _ = try? await helper.request(HelperMessages.StopCore())
    }
}
