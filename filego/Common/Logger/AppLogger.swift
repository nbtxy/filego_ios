import OSLog

nonisolated enum AppLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nbtxy.filego",
        category: "FileGo"
    )

    static func debug(
        _ message: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        logger.debug("[\(file, privacy: .public):\(line)] \(message, privacy: .public)")
    }

    static func info(
        _ message: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        logger.info("[\(file, privacy: .public):\(line)] \(message, privacy: .public)")
    }

    static func warning(
        _ message: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        logger.warning("[\(file, privacy: .public):\(line)] \(message, privacy: .public)")
    }

    static func error(
        _ message: String,
        error: Error? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        let detail = error.map { " | \($0.localizedDescription)" } ?? ""
        logger.error("[\(file, privacy: .public):\(line)] \(message + detail, privacy: .public)")
    }
}
