import Foundation

// JSON-RPC 2.0 envelope types and Codex-specific payloads.
// Designed to be permissive: any field that might disappear or change shape is optional,
// and free-form values (plan_type, limit_name) stay as String to survive new server enums.

// MARK: - Envelope

struct JSONRPCRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: Params
}

struct JSONRPCResponse: Decodable {
    let id: String?
    let result: JSONValue?
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable, Error {
    let code: Int
    let message: String
    let data: JSONValue?
}

// MARK: - initialize

struct InitializeParams: Encodable {
    struct ClientInfo: Encodable { let name: String; let version: String }
    struct Capabilities: Encodable {}
    let clientInfo: ClientInfo
    let protocolVersion: String
    let capabilities = Capabilities()
}

struct InitializeResult: Decodable {
    let userAgent: String?
    let platformFamily: String?
    let platformOs: String?
}

// MARK: - account/rateLimits/read
//
// Mirrors the upstream `chatgpt.com/backend-api/wham/usage` shape.
// **Two wire formats** in the wild:
//   - legacy snake_case: `rate_limit.{primary,secondary}_window.{used_percent,
//     limit_window_seconds, reset_after_seconds, reset_at}`,
//     `additional_rate_limits: [{limit_name, rate_limit:{...}}]`
//   - current camelCase (codex CLI ≥ 0.128): top-level `rateLimits` group
//     with `{primary,secondary}.{usedPercent, windowDurationMins, resetsAt}`
//     plus `rateLimitsByLimitId: {<id>: {limitName, primary, secondary, ...}}`
// The new format dropped `_window` suffixes, renamed `limit_window_seconds`
// (s) → `windowDurationMins` (min), and converted the additional list into a
// keyed object. Decoder accepts either silently — emit a single domain shape.
//
// We accept payload either from `result` (when the CLI doesn't choke on
// plan_type) or extracted from `error.message` body (the prolite-fallback
// path).

struct RateLimitsPayload: Decodable {
    let planType: String?           // free-form! "plus", "pro", "prolite", ...
    let rateLimit: RateLimitGroup?
    let additionalRateLimits: [AdditionalRateLimit]?

    private enum CodingKeys: String, CodingKey {
        // legacy snake_case
        case planTypeSnake = "plan_type"
        case rateLimitSnake = "rate_limit"
        case additionalRateLimitsSnake = "additional_rate_limits"
        // current camelCase (codex CLI ≥ 0.128)
        case planTypeCamel = "planType"
        case rateLimitsCamel = "rateLimits"
        case rateLimitsByLimitIdCamel = "rateLimitsByLimitId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // The new format puts planType inside the `rateLimits` object too;
        // pick whichever is present, preferring the top-level one for parity
        // with the old layout.
        let topLevelPlan = try c.decodeIfPresent(String.self, forKey: .planTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .planTypeSnake)

        // rate_limit (snake) is a RateLimitGroup with primary_window /
        // secondary_window. rateLimits (camel) is the same shape but with
        // primary / secondary keys plus inline planType.
        if let group = try c.decodeIfPresent(RateLimitGroup.self, forKey: .rateLimitsCamel) {
            self.rateLimit = group
            // Inline planType inside rateLimits wins if present.
            self.planType = group.inlinePlanType ?? topLevelPlan
        } else {
            self.rateLimit = try c.decodeIfPresent(RateLimitGroup.self, forKey: .rateLimitSnake)
            self.planType = topLevelPlan
        }

        // additional rate limits: snake = array, camel = object keyed by id.
        if let dict = try c.decodeIfPresent([String: AdditionalRateLimitWire].self,
                                            forKey: .rateLimitsByLimitIdCamel) {
            // Stable order: sort by key. Skip the entry whose limit matches
            // the headline `rateLimits` group — that's the same data the menu
            // bar already shows in the primary/secondary rows. (Camel format
            // duplicates "codex" inside both places.)
            self.additionalRateLimits = dict
                .sorted { $0.key < $1.key }
                .compactMap { (key, wire) -> AdditionalRateLimit? in
                    if key == "codex" { return nil }
                    return AdditionalRateLimit(
                        limitName: wire.limitName ?? key,
                        meteredFeature: wire.meteredFeature,
                        rateLimit: wire.asGroup())
                }
        } else if let arr = try c.decodeIfPresent([AdditionalRateLimit].self,
                                                  forKey: .additionalRateLimitsSnake) {
            self.additionalRateLimits = arr
        } else {
            self.additionalRateLimits = nil
        }
    }
}

struct RateLimitGroup: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?
    // Camel-format-only — surfaced so the parent can promote it.
    fileprivate let inlinePlanType: String?

    private enum CodingKeys: String, CodingKey {
        // shared
        case allowed
        // snake
        case limitReachedSnake = "limit_reached"
        case primaryWindowSnake = "primary_window"
        case secondaryWindowSnake = "secondary_window"
        // camel
        case limitReachedCamel = "limitReached"
        case primaryCamel = "primary"
        case secondaryCamel = "secondary"
        case inlinePlanType = "planType"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed)
        self.limitReached = try c.decodeIfPresent(Bool.self, forKey: .limitReachedCamel)
            ?? c.decodeIfPresent(Bool.self, forKey: .limitReachedSnake)
        self.primaryWindow = try c.decodeIfPresent(RateLimitWindow.self, forKey: .primaryCamel)
            ?? c.decodeIfPresent(RateLimitWindow.self, forKey: .primaryWindowSnake)
        self.secondaryWindow = try c.decodeIfPresent(RateLimitWindow.self, forKey: .secondaryCamel)
            ?? c.decodeIfPresent(RateLimitWindow.self, forKey: .secondaryWindowSnake)
        self.inlinePlanType = try c.decodeIfPresent(String.self, forKey: .inlinePlanType)
    }
}

struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        // snake
        case usedPercentSnake = "used_percent"
        case limitWindowSecondsSnake = "limit_window_seconds"
        case resetAtSnake = "reset_at"
        // camel
        case usedPercentCamel = "usedPercent"
        case windowDurationMinsCamel = "windowDurationMins"
        case resetsAtCamel = "resetsAt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercentCamel)
            ?? c.decodeIfPresent(Double.self, forKey: .usedPercentSnake)
            ?? 0
        if let mins = try c.decodeIfPresent(Int.self, forKey: .windowDurationMinsCamel) {
            self.limitWindowSeconds = mins * 60
        } else {
            self.limitWindowSeconds = try c.decodeIfPresent(Int.self,
                forKey: .limitWindowSecondsSnake) ?? 0
        }
        self.resetAt = try c.decodeIfPresent(TimeInterval.self, forKey: .resetsAtCamel)
            ?? c.decodeIfPresent(TimeInterval.self, forKey: .resetAtSnake)
            ?? 0
    }

    var resetDate: Date { Date(timeIntervalSince1970: resetAt) }
    var windowDuration: TimeInterval { TimeInterval(limitWindowSeconds) }
}

struct AdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: RateLimitGroup?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

/// Camel-format `rateLimitsByLimitId.<id>` entry. Same shape as
/// `RateLimitGroup` plus an outer `limitName` field, so we decode it
/// separately and rewrap into the legacy `AdditionalRateLimit` carrier
/// the rest of the pipeline already understands.
private struct AdditionalRateLimitWire: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let limitReached: Bool?

    func asGroup() -> RateLimitGroup {
        // Synthesize via JSON round-trip would work but it's simpler to just
        // build the value directly. RateLimitGroup is also used by the snake
        // path so we don't want to add an init that locks in camel semantics.
        let json: [String: Any] = [
            "primary": primary.map(Self.windowDict) as Any,
            "secondary": secondary.map(Self.windowDict) as Any,
            "limitReached": limitReached as Any,
        ].compactMapValues { $0 is NSNull ? nil : $0 }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (try? JSONDecoder().decode(RateLimitGroup.self, from: data))
            ?? RateLimitGroup(allowed: nil, limitReached: nil,
                              primaryWindow: nil, secondaryWindow: nil,
                              inlinePlanType: nil)
    }

    private static func windowDict(_ w: RateLimitWindow) -> [String: Any] {
        [
            "usedPercent": w.usedPercent,
            "windowDurationMins": w.limitWindowSeconds / 60,
            "resetsAt": w.resetAt,
        ]
    }
}

extension RateLimitGroup {
    /// Memberwise init used by `AdditionalRateLimitWire.asGroup()` as a
    /// fallback when JSON round-trip fails. Not used elsewhere.
    fileprivate init(
        allowed: Bool?, limitReached: Bool?,
        primaryWindow: RateLimitWindow?, secondaryWindow: RateLimitWindow?,
        inlinePlanType: String?
    ) {
        self.allowed = allowed
        self.limitReached = limitReached
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.inlinePlanType = inlinePlanType
    }
}

// MARK: - JSONValue (lossless any)

enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value")
    }

    func decode<T: Decodable>(as: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
