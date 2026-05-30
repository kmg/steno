#!/usr/bin/env swift
//
// lint-steno — custom linter for steno.
//
// Enforces structural rules from ADR-0007 (structured logging) and
// ADR-0008 (this linter). Error messages embed remediation hints so
// an AI agent can act on them directly.
//
// Run on a directory (typically `Steno/`) or one or more .swift files.
//   ./tools/lint-steno.swift Steno/
//   ./tools/lint-steno.swift Steno/Audio/RecordingPipeline.swift
//
// Exit codes:
//   0 — clean
//   1 — violations found
//   2 — argument / IO error
//
// Rules:
//   max-file-loc                    — no file over 500 lines (excluding comments + blank).
//   no-try-bang                     — no `try!` outside *Tests.swift.
//   no-print                        — no `print(` or `NSLog(` outside *Tests.swift.
//   no-bare-logger                  — no `Logger(subsystem:` outside Services/Logging/
//                                      (ADR-0007: use `StenoLog.<subsystem>` instead).
//   codable-explicit-coding-keys    — every type declared `Codable` (or `: Codable`)
//                                      includes an explicit `CodingKeys` enum.
//                                      (Catches drift between property names and JSON keys.)
//   no-private-parent-ref           — no references to a private parent repo or sibling
//                                      private project in any file. This repo is public;
//                                      such references leak information about repo layout.
//   no-inline-sdk-key               — no literal SDK keys (phc_, phx_, sk-, Sentry DSN URLs)
//                                      inline in .swift files. Move to Steno.xcconfig
//                                      and read from Bundle.main.infoDictionary at runtime.
//                                      See ADR-0009.
//
// More rules will be added as patterns surface. Each violation includes
// an explicit remediation hint for the agent reading the error.
//

import Foundation

let MAX_FILE_LOC = 500

struct Violation {
    let file: String
    let line: Int
    let rule: String
    let message: String
    let remediation: String
}

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: lint-steno <path> [<path> ...]\n".utf8))
    exit(2)
}

func lintableFiles(under path: String) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    let extensions = [".swift", ".md"]
    if !isDir.boolValue {
        return extensions.contains(where: { path.hasSuffix($0) }) ? [path] : []
    }
    var out: [String] = []
    if let e = fm.enumerator(atPath: path) {
        for case let sub as String in e {
            if extensions.contains(where: { sub.hasSuffix($0) }) {
                out.append((path as NSString).appendingPathComponent(sub))
            }
        }
    }
    return out
}

func nonBlankNonCommentLines(_ src: String) -> Int {
    var count = 0
    var inBlock = false
    for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if inBlock {
            if line.contains("*/") { inBlock = false }
            continue
        }
        if line.isEmpty { continue }
        if line.hasPrefix("//") { continue }
        if line.hasPrefix("/*") { inBlock = !line.contains("*/"); continue }
        count += 1
    }
    return count
}

/// Returns the set of (line-number, type-name) for declared types that are
/// `Codable` (or conform to `Codable`/`Decodable`/`Encodable`) anywhere in the file.
/// Does not look across files for protocol inheritance — best-effort only.
func codableTypes(_ src: String) -> [(line: Int, name: String)] {
    var out: [(Int, String)] = []
    // Match `struct/class Name : <stuff>Codable<stuff>` where Codable can
    // also be Decodable or Encodable. Enums are excluded — raw-value enums
    // encode as their raw value; enums with associated values are rare and
    // the synthesized keys are usually fine. Accept type list before/after.
    let pattern = #"^\s*(?:public|internal|fileprivate|private)?\s*(?:final\s+)?(?:struct|class)\s+(\w+)\s*:[^{]*\b(?:Codable|Decodable|Encodable)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return out }
    let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, raw) in lines.enumerated() {
        let line = String(raw)
        let range = NSRange(line.startIndex..., in: line)
        if let match = regex.firstMatch(in: line, options: [], range: range),
           let nameRange = Range(match.range(at: 1), in: line) {
            out.append((i + 1, String(line[nameRange])))
        }
    }
    return out
}

/// Heuristic: does the file body contain a `CodingKeys` enum declaration?
/// True if any line matches `enum CodingKeys`.
func hasCodingKeys(_ src: String) -> Bool {
    return src.range(of: #"\benum\s+CodingKeys\b"#, options: .regularExpression) != nil
}

/// Tokens are assembled from fragments so the literal strings don't appear
/// in this file's source (otherwise the rule's own data triggers itself
/// when this file lands in a future history-scrub pass).
let PRIVATE_PARENT_TOKENS: [String] = [
    "life" + "os",
    "tether" + "-" + "ios",
]

/// Patterns for inline SDK keys that should never appear in committed Swift code.
/// phc_/phx_ = PostHog. sk-ant- / sk-proj- = Anthropic / OpenAI. Sentry DSNs follow
/// a recognizable URL shape with @ + ingest.sentry.io.
let INLINE_SDK_KEY_PATTERNS: [(name: String, regex: String)] = [
    ("PostHog Project API key", #"\bphc_[A-Za-z0-9]{20,}"#),
    ("PostHog Personal API key", #"\bphx_[A-Za-z0-9]{20,}"#),
    ("Anthropic API key", #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
    ("OpenAI API key", #"\bsk-(?:proj-)?[A-Za-z0-9]{20,}"#),
    ("Sentry DSN", #"https://[A-Za-z0-9]{20,}@[A-Za-z0-9.-]+\.ingest\.[a-z.]*sentry\.io/\d+"#),
]

func lintPrivateParentRefs(_ src: String, file: String) -> [Violation] {
    var out: [Violation] = []
    let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, raw) in lines.enumerated() {
        let line = String(raw)
        let lower = line.lowercased()
        for token in PRIVATE_PARENT_TOKENS where lower.contains(token) {
            out.append(.init(
                file: file, line: i + 1, rule: "no-private-parent-ref",
                message: "found `\(token)` reference — this repo is public, do not leak private parent or sibling project names",
                remediation: """
                Rephrase the sentence to not name the private project. If you're describing a pattern that \
                came from another project, describe the pattern generically without naming the source. \
                If the path was a pointer to a file in another repo, inline the lesson instead — public \
                repo docs must be self-contained.
                """
            ))
            break
        }
    }
    return out
}

func lint(_ file: String) -> [Violation] {
    guard let src = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
    let isTestFile = file.hasSuffix("Tests.swift") || file.contains("StenoTests/")
    let isLoggingInfra = file.contains("Steno/Services/Logging/")
    let isLinterSelf = file.hasSuffix("lint-steno.swift")
    let isSwift = file.hasSuffix(".swift")

    var violations: [Violation] = []

    // no-private-parent-ref — applies to all lintable files. Skip the linter
    // itself since the token list is data.
    if !isLinterSelf {
        violations.append(contentsOf: lintPrivateParentRefs(src, file: file))
    }

    // The remaining rules are .swift-only.
    guard isSwift else { return violations }

    let lines = src.split(separator: "\n", omittingEmptySubsequences: false)

    // no-inline-sdk-key — applies to .swift files only. Skip the linter
    // itself since the regex patterns are data, not committed keys.
    if !isLinterSelf {
        for (i, raw) in lines.enumerated() {
            let line = String(raw)
            for pattern in INLINE_SDK_KEY_PATTERNS {
                if line.range(of: pattern.regex, options: .regularExpression) != nil {
                    violations.append(.init(
                        file: file, line: i + 1, rule: "no-inline-sdk-key",
                        message: "literal \(pattern.name) found in source — never commit SDK keys inline",
                        remediation: """
                        Move the key to Steno.xcconfig (gitignored — see Steno.xcconfig.example for the template), \
                        add an Info.plist key in Steno/Info.plist that references it via $(BUILD_VAR), and read \
                        from Bundle.main.infoDictionary at runtime. See ADR-0009. After moving, the literal must \
                        be removed from history via filter-repo if the commit was pushed.
                        """
                    ))
                }
            }
        }
    }

    // max-file-loc
    let loc = nonBlankNonCommentLines(src)
    if loc > MAX_FILE_LOC {
        violations.append(.init(
            file: file,
            line: 1,
            rule: "max-file-loc",
            message: "file exceeds \(MAX_FILE_LOC) LOC (current: \(loc))",
            remediation: """
            Refactor by extracting groups of related declarations into sibling files in the same directory. \
            For Services, split by responsibility (e.g., one file per protocol + impl). For Views, extract \
            child views into a Subviews/ subfolder. For Audio code, keep the boundary at the closure level.
            """
        ))
    }

    // codable-explicit-coding-keys — file-level heuristic
    let codable = codableTypes(src)
    if !codable.isEmpty, !hasCodingKeys(src), !isTestFile {
        for (line, name) in codable {
            violations.append(.init(
                file: file, line: line, rule: "codable-explicit-coding-keys",
                message: "type `\(name)` is Codable but file has no explicit `CodingKeys` enum",
                remediation: """
                Add a nested `enum CodingKeys: String, CodingKey { case foo, bar }` inside `\(name)` \
                listing every persisted property. Explicit keys prevent silent drift between Swift property \
                names and on-disk JSON keys, which would silently break round-trips of saved sessions.
                """
            ))
        }
    }

    // line-level checks — `lines` already computed above for the SDK-key scan.
    for (i, raw) in lines.enumerated() {
        let lineNo = i + 1
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }

        // no-try-bang
        if !isTestFile, line.contains("try!") {
            violations.append(.init(
                file: file, line: lineNo, rule: "no-try-bang",
                message: "`try!` not allowed outside *Tests.swift",
                remediation: """
                Replace `try!` with `try` inside a function marked `throws`, OR with `try?` if the call site \
                tolerates failure. If a panic-on-failure is genuinely required (e.g., programmer error in init), \
                use `precondition` with a descriptive message instead.
                """
            ))
        }

        // no-print
        if !isTestFile {
            let printCall = trimmed.range(of: #"\bprint\("#, options: .regularExpression)
            let nslogCall = trimmed.range(of: #"\bNSLog\("#, options: .regularExpression)
            if printCall != nil || nslogCall != nil {
                violations.append(.init(
                    file: file, line: lineNo, rule: "no-print",
                    message: "`print(`/`NSLog(` not allowed outside *Tests.swift",
                    remediation: """
                    Replace with `StenoLog.<subsystem>.<level>("message")` where <subsystem> is one of \
                    audio / transcription / diarization / storage / app. See \
                    Steno/Services/Logging/StenoLog.swift for the available subsystems. Each call \
                    writes to os_log AND surfaces in the in-app Debug tab (Settings → Debug).
                    """
                ))
            }
        }

        // no-bare-logger — established in ADR-0007
        if !isTestFile, !isLoggingInfra {
            let bareLogger = trimmed.range(of: #"\bLogger\(subsystem:"#, options: .regularExpression)
            if bareLogger != nil {
                violations.append(.init(
                    file: file, line: lineNo, rule: "no-bare-logger",
                    message: "`Logger(subsystem:` not allowed outside Steno/Services/Logging/ (ADR-0007)",
                    remediation: """
                    Replace with `StenoLog.<subsystem>` and remove the `import os` if no other os symbols \
                    remain. Pick the subsystem that matches the file's responsibility: audio / transcription / \
                    diarization / storage / app. Call sites stay the same (`log.info("…")`, `log.error("…")`).
                    """
                ))
            }
        }
    }

    return violations
}

let args = CommandLine.arguments.dropFirst()
if args.isEmpty { usage() }

var allViolations: [Violation] = []
for path in args {
    for file in lintableFiles(under: path) {
        allViolations.append(contentsOf: lint(file))
    }
}

if allViolations.isEmpty {
    print("steno-lint: clean")
    exit(0)
}

for v in allViolations {
    print("\(v.file):\(v.line): error: [\(v.rule)] \(v.message)")
    print("  fix: \(v.remediation)")
    print()
}
print("steno-lint: \(allViolations.count) violation(s)")
exit(1)
