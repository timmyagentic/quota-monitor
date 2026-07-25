import Foundation

extension Aggregator {
    /// Non-negative cache reads used as the numerator for every cache hit-rate
    /// surface. Keeping this SQL shared prevents History and Dashboard from
    /// drifting when imported data contains malformed negative values.
    static func cacheReadTokensExpression(table: String) -> String {
        "MAX(\(table).cached_input_tokens, 0)"
    }

    /// Provider-normalized input denominator used by cache hit rates.
    /// Codex stores the full prompt in `input_tokens`, with cached input as a
    /// subset. Claude stores uncached input separately, so reads and writes are
    /// added back; legacy unsplit writes remain a fallback for older rows.
    static func cacheEligibleInputExpression(table: String) -> String {
        """
        CASE WHEN \(table).provider = 'claude' THEN
          MAX(\(table).input_tokens, 0)
          + MAX(\(table).cached_input_tokens, 0)
          + CASE
              WHEN (MAX(\(table).cache_creation_5m_tokens, 0)
                    + MAX(\(table).cache_creation_1h_tokens, 0)) > 0
              THEN MAX(\(table).cache_creation_5m_tokens, 0)
                   + MAX(\(table).cache_creation_1h_tokens, 0)
              ELSE MAX(\(table).cache_creation_tokens, 0)
            END
        ELSE MAX(\(table).input_tokens, 0) END
        """
    }
}
