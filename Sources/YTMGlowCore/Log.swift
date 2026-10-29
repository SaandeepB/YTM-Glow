import os

/// Unified logging. View with:
/// `log stream --level info --predicate 'subsystem == "io.github.saandeepb.ytmglow"'`
public enum Log {
    public static let subsystem = "io.github.saandeepb.ytmglow"
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    public static let player = Logger(subsystem: subsystem, category: "player")
    public static let lyrics = Logger(subsystem: subsystem, category: "lyrics")
}
