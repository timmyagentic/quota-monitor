import Foundation

struct CodexSidebarQuotaTarget: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let url: String
    let webSocketDebuggerURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case url
        case webSocketDebuggerURL
    }

    static func selectValidated(
        from targets: [CodexSidebarQuotaTarget]
    ) -> CodexSidebarQuotaTarget? {
        targets.first { target in
            guard target.type == "page",
                  let pageURL = URL(string: target.url),
                  pageURL.scheme == "app",
                  pageURL.host == "-",
                  pageURL.path == "/index.html",
                  let socketURL = URL(string: target.webSocketDebuggerURL),
                  socketURL.scheme == "ws",
                  socketURL.host == "127.0.0.1",
                  socketURL.port != nil,
                  socketURL.lastPathComponent == target.id
            else { return false }
            return socketURL.path.hasPrefix("/devtools/page/")
        }
    }
}
