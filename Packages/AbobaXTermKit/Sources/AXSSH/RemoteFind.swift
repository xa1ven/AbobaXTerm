import Foundation

/// Builds and parses a `find` run for the file browser search.
public enum RemoteFind {
    /// Case-insensitive name pattern: wildcards (`*`, `?`) are used as typed,
    /// plain text matches anywhere in the name.
    public static func namePattern(for query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.contains("*") || q.contains("?") ? q : "*\(q)*"
    }

    /// Searches below `root` (not the root itself), skipping kernel pseudo
    /// file systems, printing at most `limit + 1` paths.
    public static func command(root: String, query: String, limit: Int) -> String {
        let q = ShellWords.quote
        return "find \(q(root)) -mindepth 1 \\( -path /proc -o -path /sys -o -path /dev -o -path /run \\) -prune"
            + " -o -iname \(q(namePattern(for: query))) -print 2>/dev/null | head -n \(limit + 1)"
    }

    /// Paths from `find` output, sorted; hidden entries (any component below
    /// `root` starting with a dot) are dropped unless `includeHidden`.
    public static func parse(_ output: String, root: String, includeHidden: Bool) -> [String] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return output.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .filter { path in
                includeHidden || !path.dropFirst(prefix.count).split(separator: "/").contains { $0.hasPrefix(".") }
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
