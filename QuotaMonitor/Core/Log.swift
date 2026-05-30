import Foundation
import OSLog

// Single source for OSLog categories. Use `Log.<area>.info("...")` etc.
//
// Inspect from Console.app or:
//   log stream --predicate 'subsystem == "dev.tjzhou.QuotaMonitor"' --level info

enum Log {
    static let subsystem = "dev.tjzhou.QuotaMonitor"

    static let appServer  = Logger(subsystem: subsystem, category: "appserver")
    static let importer   = Logger(subsystem: subsystem, category: "importer")
    static let poller     = Logger(subsystem: subsystem, category: "poller")
    static let pricing    = Logger(subsystem: subsystem, category: "pricing")
    static let storage    = Logger(subsystem: subsystem, category: "storage")
    static let ui         = Logger(subsystem: subsystem, category: "ui")
    static let discover   = Logger(subsystem: subsystem, category: "discover")
    static let updater    = Logger(subsystem: subsystem, category: "updater")
}
