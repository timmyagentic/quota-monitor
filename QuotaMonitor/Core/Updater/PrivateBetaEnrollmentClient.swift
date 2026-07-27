import Foundation

struct PrivateBetaEnrollment: Decodable, Sendable {
    let deviceID: String
    let token: String
}

enum PrivateBetaEnrollmentError: LocalizedError {
    case invalidCode
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return L10n.privateBetaEnrollmentRejected
        case .invalidResponse:
            return L10n.privateBetaEnrollmentFailed
        }
    }
}

struct PrivateBetaEnrollmentClient: Sendable {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func enroll(code: String, deviceLabel: String) async throws -> PrivateBetaEnrollment {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            EnrollmentRequest(code: code, deviceLabel: deviceLabel))
        request.setValue(
            String(request.httpBody?.count ?? 0),
            forHTTPHeaderField: "Content-Length")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PrivateBetaEnrollmentError.invalidResponse
        }
        guard http.statusCode == 201 else {
            throw PrivateBetaEnrollmentError.invalidCode
        }
        guard data.count <= 4_096,
              let enrollment = try? JSONDecoder().decode(
                PrivateBetaEnrollment.self, from: data),
              Self.isValidToken(enrollment.token) else {
            throw PrivateBetaEnrollmentError.invalidResponse
        }
        return enrollment
    }

    static func isValidToken(_ token: String) -> Bool {
        token.count == 43
            && token.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }

    private struct EnrollmentRequest: Encodable {
        let code: String
        let deviceLabel: String
    }
}
