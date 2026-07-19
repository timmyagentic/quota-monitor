import Foundation

struct ScanProviderProgress: Sendable, Equatable {
    let completedFiles: Int
    let totalFiles: Int
    let currentFile: String?
}

struct ScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case discovering
        case indexing
    }

    let phase: Phase
    let completedFiles: Int
    let totalFiles: Int
    let currentFile: String?

    var fraction: Double? {
        guard totalFiles > 0 else { return nil }
        let raw = Double(completedFiles) / Double(totalFiles)
        return min(1, max(0, raw))
    }
}

struct ScanProgressUpdate: Sendable, Equatable {
    let provider: String
    let completedFiles: Int
    let totalFiles: Int
    let currentFile: String?
}

typealias ScanProgressHandler = @Sendable (ScanProgressUpdate) async -> Void
