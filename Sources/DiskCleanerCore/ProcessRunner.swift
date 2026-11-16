import Foundation

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Collects pipe output from Foundation's callback threads.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// `Process` is not Sendable, but terminate() and isRunning are safe from any thread.
private final class ProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }

    /// Stops the process and everything it started. A shell killed alone leaves its children
    /// running: `a && b` keeps `a` alive, for example a `podman machine ssh` that hangs.
    func terminate() {
        guard process.isRunning else { return }
        let descendants = Self.descendants(of: process.processIdentifier)
        process.terminate()
        for pid in descendants { kill(pid, SIGTERM) }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var parents = [root]
        while let parent = parents.popLast() {
            var children = [pid_t](repeating: 0, count: 256)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), &children, Int32(children.count * MemoryLayout<pid_t>.size))
            let count = max(Int(bytes) / MemoryLayout<pid_t>.size, 0)
            let direct = children.prefix(count).filter { $0 > 0 }
            found += direct
            parents += direct
        }
        return found
    }
}

enum ProcessRunner {
    /// Runs a process without blocking Swift's cooperative threads. The process is terminated
    /// when `timeout` passes or the calling task is cancelled.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> ProcessOutput {
        // Cancellation only kills a running process, so a cancelled caller must not start one:
        // its result would be read as if the task had run normally.
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = OutputBuffer()
        let stderr = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        let handle = ProcessHandle(process)
        let timeoutTask = Task.detached {
            try await Task.sleep(for: timeout)
            handle.terminate()
            return true
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    // Take what is buffered without waiting for EOF: a grandchild process
                    // (for example one started by a shell rc file) can keep the pipe open.
                    for (pipe, buffer) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        buffer.append(readAvailable(pipe.fileHandleForReading))
                    }
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }

        timeoutTask.cancel()
        let timedOut = (try? await timeoutTask.value) == true
        return ProcessOutput(status: status, stdout: stdout.text, stderr: stderr.text, timedOut: timedOut)
    }

    private static func readAvailable(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Runs commands with the user's login-shell PATH. A GUI app starts with a bare PATH,
/// so tools from Homebrew, nvm, pyenv or uv are not found without this.
public actor Shell {
    public static let shared = Shell()

    private var cachedPath: String?
    private var pathLookup: Task<String, Never>?

    /// - Parameter path: A fixed PATH instead of the login shell's, for tests.
    public init(path: String? = nil) {
        cachedPath = path
    }

    private func loginPath() async -> String {
        if let cachedPath { return cachedPath }
        // One lookup for all callers. Detached, so a stopped scan cannot cut it short and
        // leave the fallback cached.
        let lookup = pathLookup ?? Task.detached {
            await Shell.readLoginPath() ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        pathLookup = lookup
        let path = await lookup.value
        cachedPath = path
        return path
    }

    private static func readLoginPath() async -> String? {
        // -i loads .zshrc, where nvm and pyenv usually add to PATH. Banners and prompts may
        // print first, so take the last line only.
        guard let output = try? await ProcessRunner.run("/bin/zsh", ["-lic", "print -r -- \"$PATH\""], timeout: .seconds(15)),
              !output.timedOut
        else { return nil }
        let path = output.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return path?.contains("/") == true ? path : nil
    }

    private func environment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await loginPath()
        return env
    }

    public func run(_ command: String, timeout: Duration = .seconds(1_800)) async throws -> ProcessOutput {
        try await ProcessRunner.run("/bin/zsh", ["-c", command], environment: environment(), timeout: timeout)
    }

    public func isInstalled(_ tool: String) async -> Bool {
        let output = try? await run("command -v \(Shell.quote(tool))", timeout: .seconds(10))
        return output?.succeeded == true
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
