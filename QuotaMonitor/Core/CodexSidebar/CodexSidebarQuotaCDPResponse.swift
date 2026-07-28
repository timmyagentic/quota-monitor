import Foundation

enum CodexSidebarQuotaCDPResponse {
    struct Value: Equatable, Sendable {
        let installed: Bool?

        func boolValue(named name: String) -> Bool? {
            name == "installed" ? installed : nil
        }
    }

    enum Error: Swift.Error, Equatable {
        case protocolError
        case evaluationException
        case malformedResponse
    }

    /// Returns `nil` for CDP events and responses belonging to another request.
    /// A matching Runtime.evaluate response is accepted only when both the CDP
    /// command and the JavaScript evaluation completed without an exception.
    static func parse(_ data: Data, expectedID: Int) throws -> Value? {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["id"] as? Int == expectedID
        else { return nil }
        if object["error"] != nil {
            throw Error.protocolError
        }
        guard let commandResult = object["result"] as? [String: Any] else {
            throw Error.malformedResponse
        }
        if commandResult["exceptionDetails"] != nil {
            throw Error.evaluationException
        }
        guard let remoteObject = commandResult["result"] as? [String: Any] else {
            throw Error.malformedResponse
        }
        let value = remoteObject["value"] as? [String: Any]
        return Value(installed: value?["installed"] as? Bool)
    }
}
