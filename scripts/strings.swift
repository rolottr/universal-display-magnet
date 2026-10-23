// String catalogs (.xcstrings) without Xcode: the Command Line Tools can't
// compile them, so this does what Xcode would.
//   swift scripts/strings.swift extract <catalog.xcstrings> <file.stringsdata>...
//       adds the keys the compiler found (`-emit-localized-strings`) and marks
//       the ones it no longer finds as stale, like Xcode's sync
//   swift scripts/strings.swift compile <catalog.xcstrings> <Resources dir>
//       writes <lang>.lproj/<Table>.strings, plus .stringsdict for plurals;
//       fails if a translation's format specifiers don't match its key
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("strings.swift: \(message)\n".utf8))
    exit(1)
}

func readCatalog(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path) else { return ["sourceLanguage": "en", "strings": [:], "version": "1.0"] }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("\(path) isn't a string catalog") }
    return json
}

func writeCatalog(_ catalog: [String: Any], to path: String) {
    // Xcode's own layout, so the file diffs the same whichever tool wrote it.
    let data = try! JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
}

// MARK: - Format specifiers

let specifier = try! NSRegularExpression(
    pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#)

/// The arguments a format string takes, in order: (position, conversion).
func arguments(_ format: String) -> [(Int, String)] {
    var next = 1
    var result: [(Int, String)] = []
    for m in specifier.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
        let s = format as NSString
        let conversion = s.substring(with: m.range(at: 2))
        if conversion == "%" { continue }
        let whole = s.substring(with: m.range)
        let type = conversion == "@" ? "@" : (whole.contains("ll") || whole.contains("q") ? "lld" : conversion)
        if m.range(at: 1).location != NSNotFound {
            result.append((Int(s.substring(with: m.range(at: 1)))!, type))
        } else {
            result.append((next, type))
            next += 1
        }
    }
    return result
}

/// The same string with every specifier numbered ("%@ %lld" → "%1$@ %2$lld").
func positional(_ format: String) -> String {
    var next = 1
    var out = ""
    var last = format.startIndex
    for m in specifier.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
        let range = Range(m.range, in: format)!
        out += format[last..<range.lowerBound]
        var spec = String(format[range])
        if !spec.hasSuffix("%") && m.range(at: 1).location == NSNotFound {
            spec.insert(contentsOf: "\(next)$", at: spec.index(after: spec.startIndex))
            next += 1
        } else if !spec.hasSuffix("%") {
            next += 1
        }
        out += spec
        last = range.upperBound
    }
    return out + format[last...]
}

func check(_ value: String, against key: String, plural: Bool = false, _ place: String) {
    let expected = Set(arguments(key).map { "%\($0.0)$\($0.1)" })
    let found = Set(arguments(value).map { "%\($0.0)$\($0.1)" })
    // A plural rule may leave out the count ("one" → "a window"), nothing else.
    let count = arguments(key).first { $0.1 != "@" }.map { "%\($0.0)$\($0.1)" }
    let missing = expected.subtracting(found)
    guard found.isSubset(of: expected), missing.isEmpty || (plural && missing == Set([count].compactMap { $0 })) else {
        fail("\(place): “\(value)” takes \(found.sorted()), its key “\(key)” \(expected.sorted())")
    }
}

// MARK: - extract

func extract(catalogPath: String, stringsdata: [String]) {
    var catalog = readCatalog(catalogPath)
    var strings = catalog["strings"] as? [String: Any] ?? [:]
    let table = URL(fileURLWithPath: catalogPath).deletingPathExtension().lastPathComponent
    var found: [String: String] = [:]
    for path in stringsdata {
        guard let data = FileManager.default.contents(atPath: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = (json["tables"] as? [String: Any])?[table] as? [[String: Any]]
        else { continue }
        for e in entries {
            guard let key = e["key"] as? String else { continue }
            let comment = e["comment"] as? String ?? ""
            if found[key]?.isEmpty ?? true { found[key] = comment }
        }
    }
    var added = 0, stale = 0
    for (key, comment) in found {
        var entry = strings[key] as? [String: Any] ?? { added += 1; return [:] }()
        if entry["extractionState"] as? String == "stale" { entry["extractionState"] = nil }
        if !comment.isEmpty { entry["comment"] = comment }
        strings[key] = entry
    }
    for (key, value) in strings where found[key] == nil {
        var entry = value as? [String: Any] ?? [:]
        guard entry["extractionState"] as? String != "manual", entry["extractionState"] as? String != "stale" else { continue }
        entry["extractionState"] = "stale"
        strings[key] = entry
        stale += 1
    }
    catalog["strings"] = strings
    catalog["sourceLanguage"] = catalog["sourceLanguage"] ?? "en"
    catalog["version"] = catalog["version"] ?? "1.0"
    writeCatalog(catalog, to: catalogPath)
    print("\(table): \(found.count) keys, \(added) new, \(stale) newly stale")
}

// MARK: - compile

func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}

func compile(catalogPath: String, resources: String) {
    let catalog = readCatalog(catalogPath)
    let source = catalog["sourceLanguage"] as? String ?? "en"
    let strings = catalog["strings"] as? [String: [String: Any]] ?? [:]
    let table = URL(fileURLWithPath: catalogPath).deletingPathExtension().lastPathComponent
    var languages: Set<String> = [source]
    for entry in strings.values {
        languages.formUnion((entry["localizations"] as? [String: Any])?.keys ?? [:].keys)
    }
    for language in languages.sorted() {
        var lines: [String] = []
        var plurals: [String: Any] = [:]
        for key in strings.keys.sorted() {
            let entry = strings[key]!
            if entry["shouldTranslate"] as? Bool == false && language != source { continue }
            let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
            if let unit = localization?["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                check(value, against: key, "\(table) \(language)")
                lines.append("\(quoted(key)) = \(quoted(value));")
            } else if let rules = (localization?["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                // The count is the key's first integer argument; every rule
                // gets numbered specifiers so the others still line up.
                guard let count = arguments(key).first(where: { $0.1 != "@" }) else {
                    fail("\(table) \(language): “\(key)” varies by plural but takes no number")
                }
                var variable: [String: Any] = [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": count.1,
                ]
                for (category, rule) in rules {
                    guard let value = ((rule as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                    else { continue }
                    check(value, against: key, plural: true, "\(table) \(language) \(category)")
                    variable[category] = positional(value)
                }
                guard variable["other"] != nil else { fail("\(table) \(language): “\(key)” has no “other” plural") }
                plurals[key] = ["NSStringLocalizedFormatKey": "%\(count.0)$#@count@", "count": variable]
            } else if language == source {
                // Untranslated source strings are their own key.
                continue
            }
        }
        let dir = URL(fileURLWithPath: resources).appendingPathComponent("\(language).lproj")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(table).strings"), atomically: true, encoding: .utf8)
        if !plurals.isEmpty {
            let data = try! PropertyListSerialization.data(fromPropertyList: plurals, format: .xml, options: 0)
            try! data.write(to: dir.appendingPathComponent("\(table).stringsdict"))
        }
    }
    print("\(table): \(languages.count) languages")
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "extract" where args.count >= 2: extract(catalogPath: args[args.startIndex + 1], stringsdata: Array(args.dropFirst(2)))
case "compile" where args.count == 3: compile(catalogPath: args[args.startIndex + 1], resources: args[args.startIndex + 2])
default: fail("usage: strings.swift extract <catalog> <stringsdata>… | compile <catalog> <Resources dir>")
}
