import Foundation

/// Languages the built-in editor can highlight.
public enum SyntaxLanguage: String, CaseIterable, Identifiable, Sendable {
    case plain, shell, python, json, yaml, toml, ini, xml, markdown
    case javascript, cLike, go, rust, swift, sql, dockerfile, nginx, css, lua, php, ruby, makefile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plain: "Plain Text"
        case .shell: "Shell"
        case .python: "Python"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .ini: "INI / Config"
        case .xml: "XML / HTML"
        case .markdown: "Markdown"
        case .javascript: "JavaScript / TypeScript"
        case .cLike: "C / C++ / Java"
        case .go: "Go"
        case .rust: "Rust"
        case .swift: "Swift"
        case .sql: "SQL"
        case .dockerfile: "Dockerfile"
        case .nginx: "Nginx"
        case .css: "CSS"
        case .lua: "Lua"
        case .php: "PHP"
        case .ruby: "Ruby"
        case .makefile: "Makefile"
        }
    }

    /// Guesses the language from the file name, then from a shebang line.
    public static func detect(fileName: String, content: String) -> SyntaxLanguage {
        let name = fileName.lowercased()
        if let byName = byFileName[name] { return byName }
        if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") { return .dockerfile }
        if name.hasPrefix(".bash") || name.hasPrefix(".zsh") || name == ".profile" { return .shell }

        let ext = (name as NSString).pathExtension
        if let byExt = byExtension[ext] { return byExt }
        if ext == "conf" {
            return content.range(of: #"(?m)^\s*(server|location|http|upstream)\b[^\n]*\{"#, options: .regularExpression) != nil
                ? .nginx : .ini
        }

        if content.hasPrefix("#!") {
            let firstLine = content.prefix { $0 != "\n" }
            if firstLine.contains("python") { return .python }
            if firstLine.contains("node") { return .javascript }
            if firstLine.contains("ruby") { return .ruby }
            if firstLine.contains("php") { return .php }
            if firstLine.contains("lua") { return .lua }
            if firstLine.contains("sh") { return .shell }
        }
        if content.hasPrefix("<?xml") || content.hasPrefix("<!DOCTYPE") || content.hasPrefix("<html") { return .xml }
        return .plain
    }

    private static let byFileName: [String: SyntaxLanguage] = [
        "makefile": .makefile, "gnumakefile": .makefile, "dockerfile": .dockerfile, "containerfile": .dockerfile,
        "nginx.conf": .nginx, "sshd_config": .ini, "ssh_config": .ini, "config": .ini,
        ".gitconfig": .ini, ".editorconfig": .ini, ".env": .shell, "gemfile": .ruby, "rakefile": .ruby,
        "vagrantfile": .ruby, "crontab": .shell, "authorized_keys": .plain,
    ]

    private static let byExtension: [String: SyntaxLanguage] = [
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "fish": .shell, "env": .shell,
        "py": .python, "pyw": .python, "pyi": .python,
        "json": .json, "jsonc": .json, "geojson": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "ini": .ini, "cfg": .ini, "cnf": .ini, "properties": .ini, "service": .ini, "timer": .ini,
        "socket": .ini, "mount": .ini, "network": .ini, "desktop": .ini,
        "xml": .xml, "html": .xml, "htm": .xml, "xhtml": .xml, "svg": .xml, "plist": .xml, "vue": .xml,
        "md": .markdown, "markdown": .markdown,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "ts": .javascript, "tsx": .javascript, "jsx": .javascript,
        "c": .cLike, "h": .cLike, "cc": .cLike, "cpp": .cLike, "cxx": .cLike, "hpp": .cLike, "java": .cLike,
        "kt": .cLike, "kts": .cLike, "cs": .cLike, "m": .cLike, "mm": .cLike, "groovy": .cLike, "gradle": .cLike,
        "go": .go, "rs": .rust, "swift": .swift, "sql": .sql,
        "css": .css, "scss": .css, "less": .css,
        "lua": .lua, "php": .php, "rb": .ruby, "mk": .makefile,
    ]
}
