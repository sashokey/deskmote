import Foundation

func collectAQIBody<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int) async throws -> Data? where Bytes.Element == UInt8 {
    var data = Data()
    for try await byte in bytes {
        guard data.count < limit else { return nil }
        data.append(byte)
    }
    return data
}

struct AirQualityReading {
    let index: Int
    let city: String?
    let category: String?
    let pollutants: [PollutantReading]
}

struct PollutantReading: Identifiable {
    let id: String
    let name: String
    let category: String?
    let concentration: String?
}

let pollutantNames = [
    ("NO2", "NO₂"), ("PM2_5", "PM₂.₅"), ("PM10", "PM₁₀"),
    ("O3", "O₃"), ("SO2", "SO₂"), ("CO", "CO")
]

func currentAirQuality(in html: String) -> AirQualityReading? {
    let (markup, scripts) = activeMarkup(html)
    guard let document = try? XMLDocument(xmlString: markup, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else { return nil }
    let city = localizedCity(in: document, scripts: scripts)
    pruneHiddenContent(in: document)
    guard let current = currentCard(in: document) else { return nil }
    let pollutants = pollutantNames.map { id, name in
        let card = cards(in: document, named: "airQualityPollutant\(id)").first
        return PollutantReading(
            id: id,
            name: name,
            category: card.flatMap { field("category", in: $0) },
            concentration: card.flatMap { field("pollutant-concentration", in: $0) }
        )
    }
    return AirQualityReading(index: current.index, city: city,
                             category: field("category-text", in: current.content, stopsAtHeading: true),
                             pollutants: pollutants)
}

func sourcePageURL(from value: String?) -> URL? {
    guard let value,
          let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty else { return nil }
    return parts.url
}

private func pruneHiddenContent(in document: XMLDocument) {
    for element in elements(in: document, matching: "//*[@hidden][not(ancestor::*[@hidden])]") { element.detach() }
}

private func activeMarkup(_ html: String) -> (String, [String]) {
    let attributes = #"(?:[^"'<>]++|"[^"]*+"|'[^']*+')*+"#
    let delimiter = #"(?=[\t\n\f\r />])"#
    let expression = try! NSRegularExpression(pattern:
        #"(?is)<!--.*?(?:-->|$)|<(script|style|textarea|title|noscript|iframe|xmp|noembed|noframes)"# + delimiter + attributes +
        #">(.*?)(?:</\1"# + delimiter + attributes + #">|$)|<(/?)template"# + delimiter + attributes +
        ">|(</?[a-z]" + attributes + ">)")
    let source = html as NSString
    var visible = ""
    var scripts: [String] = []
    var cursor = 0
    var templateDepth = 0
    expression.enumerateMatches(in: html, range: NSRange(location: 0, length: source.length)) { match, _, _ in
        guard let match else { return }
        if templateDepth == 0 {
            visible += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let rawText = match.range(at: 1)
            let isScript = rawText.location != NSNotFound && source.substring(with: rawText).lowercased() == "script"
            let body = match.range(at: 2)
            if isScript, body.location != NSNotFound {
                visible += source.substring(with: NSRange(location: match.range.location,
                    length: body.location - match.range.location))
                visible += String(scripts.count)
                scripts.append(source.substring(with: body))
                visible += source.substring(with: NSRange(location: NSMaxRange(body),
                    length: NSMaxRange(match.range) - NSMaxRange(body)))
            } else if match.range(at: 4).location != NSNotFound {
                visible += source.substring(with: match.range)
            }
        }
        let template = match.range(at: 3)
        if template.location != NSNotFound {
            templateDepth = max(0, templateDepth + (template.length == 0 ? 1 : -1))
        }
        cursor = NSMaxRange(match.range)
    }
    if templateDepth == 0 { visible += source.substring(from: cursor) }
    return (visible, scripts)
}

private func elements(in node: XMLNode, matching xpath: String) -> [XMLElement] {
    (try? node.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }) ?? []
}

private func hasClass(_ name: String, on element: XMLElement) -> Bool {
    guard let classNames = element.attribute(forName: "class")?.stringValue else { return false }
    let target = Array(name.utf8)
    return classNames.utf8.split { [9, 10, 12, 13, 32].contains($0) }.contains { $0.elementsEqual(target) }
}

private func field(_ name: String, in card: XMLElement, stopsAtHeading: Bool = false) -> String? {
    for element in elements(in: card, matching: ".//*") {
        if element.attribute(forName: "data-qa") != nil ||
            (stopsAtHeading && ["h1", "h2", "h3", "h4", "h5", "h6"].contains(element.localName)) { return nil }
        guard ["p", "div"].contains(element.localName), hasClass(name, on: element) else { continue }
        let boundaries = ".//*[@data-qa or local-name()='script' or local-name()='h1' or local-name()='h2' or " +
            "local-name()='h3' or local-name()='h4' or local-name()='h5' or local-name()='h6']"
        let value: String?
        if elements(in: element, matching: boundaries).isEmpty {
            value = element.stringValue
        } else {
            guard let copy = element.copy() as? XMLElement else { return nil }
            for nested in elements(in: copy, matching: boundaries) { nested.detach() }
            value = copy.stringValue
        }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
    return nil
}

private func cards(in document: XMLDocument, named name: String) -> [XMLElement] {
    let cardNames = ["airQualityCard"] + pollutantNames.map { "airQualityPollutant\($0.0)" }
    let ancestorCard = cardNames.map { "@data-qa='\($0)'" }.joined(separator: " or ")
    return elements(in: document, matching: "//*[local-name()='div'][@data-qa='\(name)'][not(ancestor::*[\(ancestorCard)])]")
}

private func currentCard(in document: XMLDocument) -> (index: Int, content: XMLElement)? {
    for card in cards(in: document, named: "airQualityCard") {
        let contents = elements(in: card, matching: "./*[local-name()='div'][not(@data-qa)][preceding-sibling::*[1][local-name()='h2']]")
        guard let content = contents.first(where: { hasClass("air-quality-content", on: $0) }),
              let number = field("aq-number", in: content, stopsAtHeading: true),
              !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
              let index = Int(number) else { continue }
        return (index, content)
    }
    return nil
}

private struct PageLocation: Decodable {
    let localizedName: String
}

private let javascriptMIMETypes: Set<String> = [
    "application/ecmascript", "application/javascript", "application/x-ecmascript", "application/x-javascript",
    "text/ecmascript", "text/javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
    "text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript",
    "text/x-ecmascript", "text/x-javascript"
]

private func isInlineJavaScript(_ element: XMLElement) -> Bool {
    guard element.attribute(forName: "src") == nil else { return false }
    let type = element.attribute(forName: "type")?.stringValue
    let language = element.attribute(forName: "language")?.stringValue ?? ""
    if type?.lowercased() == "module" { return true }
    let asciiWhitespace = CharacterSet(charactersIn: "\t\n\u{000C}\r ")
    let classicType = type.map {
        $0.isEmpty ? "text/javascript" : $0.trimmingCharacters(in: asciiWhitespace).lowercased()
    } ?? (language.isEmpty ? "text/javascript" : "text/" + language.lowercased())
    return javascriptMIMETypes.contains(classicType) && element.attribute(forName: "nomodule") == nil
}

private func localizedCity(in document: XMLDocument, scripts: [String]) -> String? {
    let quoted = #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#
    let comment = #"(?:/\*.*?(?:\*/|$)|(?://|<!--)[^\r\n\u2028\u2029]*|(?m:^[ \t]*-->[^\r\n\u2028\u2029]*))"#
    let whitespace = "(?:" + comment + "|\\s++)"
    let trivia = whitespace + "*+"
    let identifier = #"[$_\p{L}][$_\p{L}\p{N}\p{M}]*"#
    let tokens = try! NSRegularExpression(pattern: "(?s)(" + whitespace + ")|(?:" + quoted +
        ")|" + identifier + #"|=>|\+\+|--|."#)
    let regexLiteral = try! NSRegularExpression(
        pattern: #"/(?![/*])(?:\\.|\[(?:\\.|[^\]\\\r\n\u2028\u2029])*\]|[^/\\\r\n\u2028\u2029\[])+/[a-z]*"#)
    let declaration = try! NSRegularExpression(pattern: "(?s)" + trivia + #"\bcurrentLocation\b"# + trivia +
        "=" + trivia + #"(\{)"#)
    let terminator = try! NSRegularExpression(pattern: "(?s)(" + trivia +
        #")([;}]|\z|(?!(?:in|instanceof)\b)(?:[$_\p{L}][$_\p{L}\p{M}\p{N}]*|[0-9]+|\.(?=[0-9])|['"{~]|!(?!=)|\+\+|--))"#)
    let options: NSRegularExpression.MatchingOptions = [.anchored, .withTransparentBounds, .withoutAnchoringBounds]
    var city: String?
    for element in elements(in: document, matching: "//*[local-name()='script']") {
        guard isInlineJavaScript(element), let placeholder = element.stringValue,
              let index = Int(placeholder.trimmingCharacters(in: .whitespacesAndNewlines)),
              scripts.indices.contains(index) else { continue }
        let script = scripts[index]
        let isModule = element.attribute(forName: "type")?.stringValue?.lowercased() == "module"
        var cursor = script.startIndex
        var previous = ""
        var beforePrevious = ""
        var expectsOperand = true
        var parens: [(control: Bool, functionExpression: Bool, asyncFunction: Bool?, asyncArrow: Bool)] = []
        var pendingFunctionExpression = false
        var closedFunctionExpression = false
        var pendingAsyncFunction: Bool?
        var closedAsyncFunction: Bool?
        var closedAsyncArrow = false
        var statementBraces: [Bool] = []
        var asyncContext: [Bool] = []
        var bracketDepth = 0
        var expressionArrows: [(depth: Int, braceDepth: Int, isAsync: Bool)] = []
        while cursor < script.endIndex,
              let match = tokens.firstMatch(in: script, options: options, range: NSRange(cursor..., in: script)),
              let matched = Range(match.range, in: script) {
            cursor = matched.upperBound
            if match.range(at: 1).location != NSNotFound { continue }
            let token = String(script[matched])
            if token == "\u{0060}" {
                cursor = templateEnd(in: script, after: cursor)
                expectsOperand = false
                previous = ")"
                continue
            }
            if token == "/", expectsOperand, let regex = regexLiteral.firstMatch(
                in: script, options: options, range: NSRange(matched.lowerBound..., in: script)
            ), let range = Range(regex.range, in: script) {
                cursor = range.upperBound
                expectsOperand = false
                previous = ")"
                continue
            }
            if ["var", "let", "const"].contains(token), previous != ".",
               let assignment = declaration.firstMatch(in: script, options: options, range: NSRange(cursor..., in: script)),
               let start = Range(assignment.range(at: 1), in: script)?.lowerBound,
               let object = locationObject(in: script, startingAt: start, endingWith: terminator),
               let location = try? JSONDecoder().decode(PageLocation.self, from: object.data) {
                cursor = object.end
                let name = location.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    if let city, city != name { return nil }
                    city = name
                }
                expectsOperand = false
                previous = "}"
                continue
            }
            let depth = parens.count + statementBraces.count + bracketDepth
            if [")", "]", "}", ",", ";"].contains(token) {
                while let arrow = expressionArrows.last, arrow.depth >= depth {
                    expressionArrows.removeLast()
                }
            }
            let inheritedAsync: Bool
            if let arrow = expressionArrows.last, arrow.braceDepth == statementBraces.count {
                inheritedAsync = arrow.isAsync
            } else {
                inheritedAsync = asyncContext.last ?? isModule
            }
            switch token {
            case _ where previous == ".":
                expectsOperand = false
            case "function":
                let context = previous == "async" ? beforePrevious : previous
                pendingFunctionExpression = !context.isEmpty && ![";", "{", "}", "export", "default"].contains(context)
                pendingAsyncFunction = previous == "async"
                expectsOperand = true
            case "(":
                let asynchronousMethod = beforePrevious == "async" && previous != "async" && previous != "function"
                let loopOrCondition = ["if", "while", "for", "with", "switch", "catch"].contains(previous)
                    || (beforePrevious == "for" && previous == "await")
                parens.append((loopOrCondition,
                               pendingFunctionExpression, pendingAsyncFunction ?? (asynchronousMethod ? true : nil), previous == "async"))
                pendingFunctionExpression = false
                pendingAsyncFunction = nil
                expectsOperand = true
            case ")":
                let context = parens.popLast()
                closedFunctionExpression = context?.functionExpression == true
                closedAsyncFunction = context?.asyncFunction
                closedAsyncArrow = context?.asyncArrow == true
                expectsOperand = context?.control == true
            case "=>":
                let isAsync = (previous == ")" && closedAsyncArrow) || beforePrevious == "async"
                expressionArrows.append((depth, statementBraces.count, isAsync))
                expectsOperand = true
            case "{":
                let statement = previous.isEmpty || [";", ")", "else", "do", "try", "finally", "{", "}"].contains(previous)
                statementBraces.append(statement && !(previous == ")" && closedFunctionExpression))
                let asyncFunction = previous == "=>" ? expressionArrows.popLast()?.isAsync :
                    (previous == ")" ? closedAsyncFunction : nil)
                asyncContext.append(asyncFunction ?? inheritedAsync)
                expectsOperand = true
            case "}":
                expectsOperand = statementBraces.popLast() ?? true
                _ = asyncContext.popLast()
            case "[":
                bracketDepth += 1
                expectsOperand = true
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                expectsOperand = false
            case "++", "--":
                break
            default:
                expectsOperand = [";", ",", ":", "=", "?", "!", "+", "-", "*", "%", "~", "/",
                                  "&", "|", "^", "<", ">", "return", "throw", "case", "yield", "else", "do",
                                  "delete", "void", "typeof", "in", "instanceof"].contains(token)
                    || (inheritedAsync && token == "await")
            }
            beforePrevious = previous
            previous = token
        }
    }
    return city
}

private func templateEnd(in script: String, after start: String.Index) -> String.Index {
    let bytes = script.utf8
    var delimiters: [UInt8] = [96]
    var index = start
    while index < bytes.endIndex, let delimiter = delimiters.last {
        let byte = bytes[index]
        bytes.formIndex(after: &index)
        if byte == 92, index < bytes.endIndex {
            bytes.formIndex(after: &index)
        } else if byte == delimiter {
            delimiters.removeLast()
        } else if delimiter == 96 {
            if byte == 36, index < bytes.endIndex, bytes[index] == 123 {
                delimiters.append(125)
                bytes.formIndex(after: &index)
            }
        } else if delimiter == 125 {
            switch byte {
            case 34, 39, 96: delimiters.append(byte)
            case 123: delimiters.append(125)
            case 47 where index < bytes.endIndex && bytes[index] == 47:
                index = bytes[index...].firstIndex(where: { $0 == 10 || $0 == 13 }) ?? bytes.endIndex
            case 47 where index < bytes.endIndex && bytes[index] == 42:
                bytes.formIndex(after: &index)
                while index < bytes.endIndex {
                    let wasAsterisk = bytes[index] == 42
                    bytes.formIndex(after: &index)
                    if wasAsterisk, index < bytes.endIndex, bytes[index] == 47 {
                        bytes.formIndex(after: &index)
                        break
                    }
                }
            default: break
            }
        }
        if delimiters.count > 64 { return bytes.endIndex }
    }
    return index
}

private func locationObject(in script: String, startingAt start: String.Index, endingWith terminator: NSRegularExpression)
    -> (data: Data, end: String.Index)? {
    let bytes = script.utf8[start...].prefix(64 * 1024)
    var depth = 0
    var quoted = false
    var escaped = false
    var keyStart: String.Index?
    var foundNameKey = false
    for index in bytes.indices {
        let byte = bytes[index]
        if quoted {
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                quoted = false
                if let keyStart {
                    let end = bytes.index(after: index)
                    let following = bytes[end...].first(where: { ![9, 10, 13, 32].contains($0) })
                    if following == 58,
                       (try? JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<end]))) == "localizedName" {
                        guard !foundNameKey else { return nil }
                        foundNameKey = true
                    }
                }
                keyStart = nil
            }
        } else if byte == 34 {
            quoted = true
            if depth == 1 { keyStart = index }
        } else if byte == 123 {
            depth += 1
        } else if byte == 125 {
            depth -= 1
            if depth == 0 {
                let end = bytes.index(after: index)
                let suffix = NSRange(end..<script.endIndex, in: script)
                guard let match = terminator.firstMatch(in: script, options: .anchored, range: suffix) else { return nil }
                if let token = Range(match.range(at: 2), in: script),
                   !["", ";", "}"].contains(String(script[token])) {
                    guard let whitespace = Range(match.range(at: 1), in: script),
                          script[whitespace].contains(where: \.isNewline) else { return nil }
                }
                return (Data(bytes[..<end]), end)
            }
        }
    }
    return nil
}
