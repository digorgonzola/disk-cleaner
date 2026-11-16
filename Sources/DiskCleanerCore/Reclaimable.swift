import Foundation

/// What a rule's clean command can free, as its tool reports it. For a VM disk image the
/// folder size counts everything in the VM, most of which the clean keeps.
public enum Reclaimable: Sendable, Hashable {
    /// The tool has not answered yet.
    case pending
    case bytes(Int64)
    /// The tool did not answer, for example because the VM is stopped.
    case unknown(reason: String)
}

/// Asks a tool how much its clean command can free. For rules with one home path: the
/// answer is for the whole tool, so a second path would count it twice.
public struct ReclaimableQuery: Sendable {
    /// Prints one `<label>=<size>` line per kind of data, such as `system df` with a format.
    /// Text after the size, such as "(45%)", is ignored. Start it with `exec`, so that
    /// stopping the shell stops the tool.
    public let command: String
    /// Labels of the data the clean keeps, such as volumes.
    public let excludedLabels: Set<String>

    public init(command: String, excludedLabels: Set<String> = []) {
        self.command = command
        self.excludedLabels = excludedLabels
    }

    /// `system df` in VMs with large volumes can take half a minute.
    static let timeout: Duration = .seconds(180)

    /// - Returns: `nil` when the task is cancelled. There is then no new answer, and the
    ///   caller keeps the one it has.
    public func estimate(shell: Shell = .shared) async -> Reclaimable? {
        let output: ProcessOutput
        do {
            output = try await shell.run(command, timeout: Self.timeout)
        } catch {
            return Task.isCancelled ? nil : .unknown(reason: error.localizedDescription)
        }
        return Task.isCancelled ? nil : parse(output)
    }

    func parse(_ output: ProcessOutput) -> Reclaimable {
        guard output.succeeded else {
            let lastError = output.stderr.split(whereSeparator: \.isNewline).last
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let reason = output.timedOut ? "the tool did not answer in time" : lastError ?? "exit status \(output.status)"
            return .unknown(reason: String(reason.prefix(160)))
        }
        var total: Int64 = 0
        var sizesRead = 0
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            guard let separator = line.lastIndex(of: "=") else { continue }
            let label = line[..<separator].trimmingCharacters(in: .whitespaces)
            let sizeText = line[line.index(after: separator)...].split(separator: " ").first.map(String.init) ?? ""
            guard let size = Self.bytes(sizeText) else { continue }
            sizesRead += 1
            guard !excludedLabels.contains(label) else { continue }
            let (sum, overflow) = total.addingReportingOverflow(size)
            total = overflow ? .max : sum
        }
        return sizesRead > 0 ? .bytes(total) : .unknown(reason: "the tool's answer was not a size")
    }

    /// Decimal units, as Docker and Podman print them.
    private static let unitScale: [String: Double] = ["": 1, "B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]

    /// Reads "510825984", "0B" or "1.5GB".
    static func bytes(_ text: String) -> Int64? {
        let number = text.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard let value = Double(number), let scale = unitScale[String(text.dropFirst(number.count))] else { return nil }
        return Int64(exactly: (value * scale).rounded())
    }
}
