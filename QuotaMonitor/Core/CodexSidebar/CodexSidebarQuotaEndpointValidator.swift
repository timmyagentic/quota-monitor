import Foundation

enum CodexSidebarQuotaEndpointValidator {
    static func listenerBelongsToCodex(
        lsofOutput: String,
        applicationPID: pid_t
    ) -> Bool {
        let listeners = Set(lsofOutput.split(separator: "\n").compactMap { line -> pid_t? in
            guard line.first == "p" else { return nil }
            return pid_t(line.dropFirst())
        })
        return listeners == [applicationPID]
    }

    static func listenerBelongsToCodex(
        port: Int,
        applicationPID: pid_t
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [
            "-nP",
            "-iTCP:\(port)",
            "-sTCP:LISTEN",
            "-Fp"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return listenerBelongsToCodex(
                lsofOutput: String(decoding: data, as: UTF8.self),
                applicationPID: applicationPID)
        } catch {
            return false
        }
    }
}
