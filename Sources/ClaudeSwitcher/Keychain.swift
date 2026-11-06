import Foundation

/// Talks to the login keychain through `/usr/bin/security`.
///
/// Claude Code creates its credential item with the `security` tool, so that
/// binary is already on the item's access list. Going through it (instead of
/// SecItem APIs) means no "allow access" prompts on every read.
enum Keychain {
    enum KeychainError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .writeFailed(let msg): return "Keychain write failed: \(msg)"
            }
        }
    }

    static func read(service: String, account: String) -> String? {
        let result = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Writes via `security -i` on stdin where possible so the secret stays out of `ps` output.
    static func write(service: String, account: String, value: String) throws {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)\n"
        // `security -i` truncates long input lines (~4 KB). Claude Code falls back to argv
        // for big payloads too; it briefly exposes the hex to same-user `ps`.
        let result = command.utf8.count <= 4000
            ? run(["-i"], stdin: command)
            : run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        // `security -i` exits 0 even when a command fails, so verify by reading back.
        guard read(service: service, account: account) == value else {
            throw KeychainError.writeFailed(result.stderr.isEmpty ? "value did not persist" : result.stderr)
        }
    }

    static func delete(service: String, account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private static func run(_ args: [String], stdin: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
