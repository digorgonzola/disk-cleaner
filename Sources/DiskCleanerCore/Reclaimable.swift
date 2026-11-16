import Foundation

/// What a rule's clean command can free, as its tool reports it. For a VM disk image the
/// folder size counts everything in the VM, most of which the clean keeps.
public enum Reclaimable: Sendable, Hashable {
    case bytes(Int64)
    /// The tool did not answer, for example because the VM is stopped.
    case unknown(reason: String)

    /// Runs a rule's `reclaimableCommand` with the login PATH.
    public static func estimate(_ command: String) async -> Reclaimable {
        do {
            return parse(try await Shell.shared.run(command, timeout: .seconds(60)))
        } catch {
            return .unknown(reason: error.localizedDescription)
        }
    }

    /// Takes the byte count from the last line of output.
    static func parse(_ output: ProcessOutput) -> Reclaimable {
        let lastLine = { (text: String) in
            text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard output.succeeded else {
            let reason = output.timedOut ? "the tool did not answer in time" : lastLine(output.stderr) ?? "exit status \(output.status)"
            return .unknown(reason: String(reason.prefix(160)))
        }
        guard let line = lastLine(output.stdout), let bytes = Int64(line), bytes >= 0 else {
            return .unknown(reason: "the tool's answer was not a size")
        }
        return .bytes(bytes)
    }
}
