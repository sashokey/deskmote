import Foundation

@main
struct CheckAQI {
    static func main() async throws {
        let forecast = #"<div class="aq-number">88</div>"#
        let current = """
        <div data-qa="airQualityCard">
          <h2>Current air quality</h2>
          <div class="air-quality-content">
            <div class="aq-number">37</div>
            <p class="category-text">&#x421;&#x440;&#x435;&#x434;&#x43D;&#x438;&#x439;</p>
          </div>
        </div>
        """
        let pollutantCards = pollutantNames.enumerated().map { index, item in
            """
            <div data-qa="airQualityPollutant\(item.0)">
              <div class="category">&#x421;&#x440;&#x435;&#x434;&#x43D;&#x438;&#x439;</div>
              <div class="pollutant-concentration">\(index + 1) &#xB5;g/m&#xB3;</div>
            </div>
            """
        }
        let html = ([forecast, current] + pollutantCards).joined()
        let reading = currentAirQuality(in: html)
        precondition(currentAirQuality(in: forecast) == nil)
        precondition(reading?.index == 37)
        precondition(reading?.category == "Средний")
        let missingIndex = current.replacingOccurrences(of: #"<div class="aq-number">37</div>"#, with: "")
        precondition(currentAirQuality(in: missingIndex + forecast) == nil,
                     "A number after the current card must never be used")
        let nestedForecast = current.replacingOccurrences(of: #"<div class="aq-number">37</div>"#,
            with: #"<div data-qa="forecast"><h3>Forecast</h3><div class="aq-number">88</div></div>"#)
        precondition(currentAirQuality(in: nestedForecast) == nil, "A nested forecast cannot supply the current index")
        let enclosedForecast = current.replacingOccurrences(of: ">37<",
            with: #"><span data-qa="forecast">88</span><"#)
        precondition(currentAirQuality(in: enclosedForecast) == nil, "A nested forecast is not the text of the current index")
        let foreignContent = current.replacingOccurrences(of: #"class="air-quality-content""#,
            with: #"class="air-quality-content" data-qa="forecast""#)
        precondition(currentAirQuality(in: foreignContent) == nil)
        let oldCard = current.replacingOccurrences(of: ">37<", with: ">88<")
        let nestedCard = missingIndex.replacingOccurrences(of: "</h2>", with: "</h2>" + oldCard)
        precondition(currentAirQuality(in: nestedCard + current)?.index == 37)
        precondition(currentAirQuality(in: "<noscript>" + oldCard + "</noscript>" + current)?.index == 37)
        precondition(currentAirQuality(in: "<iframe>" + oldCard + "</iframe>" + current)?.index == 37)
        let falseCurrent = oldCard.replacingOccurrences(of: "</h2>", with: "</h2><h3>Forecast</h3>")
        precondition(currentAirQuality(in: falseCurrent + current)?.index == 37)
        let emptyCategory = current.replacingOccurrences(of: "&#x421;&#x440;&#x435;&#x434;&#x43D;&#x438;&#x439;", with: "  ")
        precondition(currentAirQuality(in: emptyCategory)?.category == nil)
        let hiddenValue = current.replacingOccurrences(of: ">37<", with: "><span hidden>88</span>37<")
        precondition(currentAirQuality(in: hiddenValue)?.index == 37)
        precondition(currentAirQuality(in: "<div hidden>" + nestedForecast + "</div>" + current)?.index == 37)
        let decoratedValue = current.replacingOccurrences(of: ">37<",
            with: ">37<script>window.loaded = true;</script><")
        precondition(currentAirQuality(in: decoratedValue)?.index == 37, "The index uses visible text")
        let secondCard = current.replacingOccurrences(of: ">37<", with: ">45<")
            .replacingOccurrences(of: "&#x421;&#x440;&#x435;&#x434;&#x43D;&#x438;&#x439;", with: "Moderate")
        let repeated = currentAirQuality(in: missingIndex + secondCard)
        precondition(repeated?.index == 45 && repeated?.category == "Moderate",
                     "The category and index must come from the same card")
        let comment = current.replacingOccurrences(of: #"<div class="aq-number">"#,
                                              with: #"<!-- </div> data-qa="unused" --><div class="aq-number">"#)
        precondition(currentAirQuality(in: comment)?.index == 37, "Markup in a comment cannot change the card boundary")
        let quotedTemplate = #"<div data-preview='<template>'></div><div data-preview="<!-- comment"></div>"#
        precondition(currentAirQuality(in: quotedTemplate + html)?.index == 37,
                     "Markup in quoted attribute values cannot hide the current card")
        let lookalike = current.replacingOccurrences(of: #"<div class="aq-number">"#,
                                                with: #"<div data-class="aq-number">88</div><div class='aq-number'>"#)
        precondition(currentAirQuality(in: lookalike)?.index == 37, "Only the actual class attribute identifies the current value")
        let nonASCIISpace = current.replacingOccurrences(of: #"<div class="aq-number">"#,
            with: #"<div class="old&nbsp;aq-number">88</div><div class="aq-number">"#)
        precondition(currentAirQuality(in: nonASCIISpace)?.index == 37, "A nonbreaking space stays inside the class token")
        precondition(reading?.pollutants.map(\.name) == ["NO₂", "PM₂.₅", "PM₁₀", "O₃", "SO₂", "CO"])
        precondition(reading?.pollutants.map(\.category) == Array(repeating: "Средний", count: 6))
        precondition(reading?.pollutants.map(\.concentration) == ["1 µg/m³", "2 µg/m³", "3 µg/m³", "4 µg/m³", "5 µg/m³", "6 µg/m³"])
        let titled = pollutantCards[0].replacingOccurrences(of: "<div class=\"category\">",
            with: "<h3>NO₂</h3><div class=\"category\">")
        let packaged = current + #"<section data-qa="airQualityPollutants">"# + titled + "</section>"
        precondition(currentAirQuality(in: packaged)?.pollutants.first?.concentration == "1 µg/m³")
        let namedUnits = html.replacingOccurrences(of: "&#xB5;g/m&#xB3;", with: "&micro;g/m&sup3;")
        let decimalUnits = html.replacingOccurrences(of: "&#xB5;g/m&#xB3;", with: "&#181;g/m&#179;")
        precondition(currentAirQuality(in: namedUnits)?.pollutants.first?.concentration == "1 µg/m³")
        precondition(currentAirQuality(in: decimalUnits)?.pollutants.first?.concentration == "1 µg/m³")
        let partial = currentAirQuality(in: current + pollutantCards.dropFirst().joined())
        precondition(partial?.pollutants.first?.concentration == nil)
        precondition(partial?.pollutants.last?.concentration == "6 µg/m³")
        let hiddenPollutant = pollutantCards[0].replacingOccurrences(of: ">1 ", with: ">999 ")
        let visiblePollutants = currentAirQuality(in: "<!--\(hiddenPollutant)--><template>\(hiddenPollutant)</template>" + html)
        precondition(visiblePollutants?.pollutants.first?.concentration == "1 µg/m³")
        let location = #"<script>var currentLocation = {"administrativeArea":{"localizedName":"Wrong Region"},"localizedName":"Труа-Ривьер, Квебек"};</script>"#
        precondition(currentAirQuality(in: location + html)?.city == "Труа-Ривьер, Квебек")
        precondition(reading?.city == nil)
        let emptyLocation = #"<script>var currentLocation = {"localizedName":" "};</script>"#
        precondition(currentAirQuality(in: emptyLocation + html)?.city == nil)
        let escapedLocation = #"<script>var currentLocation = {"localizedName":"Z\u00FCrich"};</script>"#
        precondition(currentAirQuality(in: escapedLocation + html)?.city == "Zürich")
        let multipleLocations = #"""
        <script>
        // var currentLocation = {"localizedName":"Commented out"};
        const preview = 'var currentLocation = {"localizedName":"Preview"};';
        var currentLocation = {"localizedName": invalid};
        currentLocation = {};
        var currentLocation = {"localizedName":"London"};
        </script>
        """#
        precondition(currentAirQuality(in: multipleLocations + html)?.city == "London",
                     "Only a decodable declaration in the script can supply the city")
        let commentedLocation = #"""
        <script>
        const templatePattern = /var currentLocation = {"localizedName":"Fixture"};/;
        const /* location */ currentLocation = {"localizedName":"London"}
        </script>
        """#
        precondition(currentAirQuality(in: commentedLocation + html)?.city == "London",
                     "A regular expression cannot supply the city and a comment can separate declaration tokens")
        let dataBlock = #"<script type="text/plain">var currentLocation = {"localizedName":"Sample"};</script>"#
        precondition(currentAirQuality(in: dataBlock + commentedLocation + html)?.city == "London")
        let nonModule = #"<script nomodule>var currentLocation = {"localizedName":"Fallback"};</script>"#
        let computed = #"<script>var currentLocation = {"localizedName":"Prefix"} /* computed */ .filter;</script>"#
        let legacyScript = #"<script type="application/x-javascript">var currentLocation = {"localizedName":"London"};</script>"#
        precondition(currentAirQuality(in: nonModule + computed + legacyScript + html)?.city == "London")
        let inlineHidden = #"""
        <div hidden><script>
        const currentLocation = {"localizedName":"London"}
        const anotherVariable = 1;
        </script></div>
        """#
        precondition(currentAirQuality(in: inlineHidden + html)?.city == "London")
        let expressionThenLocation = #"""
        <script>
        /var currentLocation = {"localizedName":"Fixture"};/.test(text);
        const currentLocation = {"localizedName":"London"}
        render();
        </script>
        """#
        precondition(currentAirQuality(in: expressionThenLocation + html)?.city == "London")
        let lexicalContexts = #"""
        <script>
        if (ready) /var currentLocation = {"localizedName":"Fixture"};/.test(text);
        const preview = `${`before`} var currentLocation = {"localizedName":"Fixture"};`;
        obj.var
        currentLocation = {"localizedName":"Fixture"};
        const currentLocation = {"localizedName":"London"}
        !ready && render();
        </script>
        """#
        precondition(currentAirQuality(in: lexicalContexts + html)?.city == "London")
        let classicComment = #"""
        <script>
        <!-- var currentLocation = {"localizedName":"Fixture"};
        const currentLocation = {"localizedName":"London"};
        </script>
        """#
        precondition(currentAirQuality(in: classicComment + html)?.city == "London")
        let division = #"<script>const a = measure() / 2; const currentLocation = {"localizedName":"London"}; const b = 6 / 2;</script>"#
        precondition(currentAirQuality(in: division + html)?.city == "London")
        let functionDivision = #"<script>const a = function() {} / 2; const currentLocation = {"localizedName":"London"}; const b = 6 / 2;</script>"#
        precondition(currentAirQuality(in: functionDivision + html)?.city == "London")
        let moduleRegex = #"<script type="module">const a = await /var currentLocation = {"localizedName":"Fixture"};/;</script>"#
        precondition(currentAirQuality(in: moduleRegex + html)?.city == nil)
        let postfixDivision = #"<script>let n = 8; const a = n++ / 2; const currentLocation = {"localizedName":"London"}; const b = 6 / 2;</script>"#
        precondition(currentAirQuality(in: postfixDivision + html)?.city == "London")
        let asyncRegex = #"<script>async function check() { await /var currentLocation = {"localizedName":"Fixture"};/; } const currentLocation = {"localizedName":"London"};</script>"#
        precondition(currentAirQuality(in: asyncRegex + html)?.city == "London")
        let asyncArrow = #"<script>const run = async () => { await /var currentLocation = {"localizedName":"Fixture"};/; }; const currentLocation = {"localizedName":"London"};</script>"#
        precondition(currentAirQuality(in: asyncArrow + html)?.city == "London")
        let asyncExpression = #"<script>const run = (async () => await /var currentLocation = {"localizedName":"Fixture"};/); const a = await / 2; const currentLocation = {"localizedName":"London"}; const b = 6 / 2;</script>"#
        precondition(currentAirQuality(in: asyncExpression + html)?.city == "London")
        let repeatedBinding = #"<script>var currentLocation = {"localizedName":"Paris"}, currentLocation = {"localizedName":"London"};</script>"#
        precondition(currentAirQuality(in: repeatedBinding + html)?.city == nil)
        let propertyDivision = #"<script>const a = obj.return / 2; const currentLocation = {"localizedName":"London"}; const b = 6 / 2;</script>"#
        precondition(currentAirQuality(in: propertyDivision + html)?.city == "London")
        let elseRegex = #"<script>if (ready) render(); else /var currentLocation = {"localizedName":"Fixture"};/.test(text); const currentLocation = {"localizedName":"London"};</script>"#
        precondition(currentAirQuality(in: elseRegex + html)?.city == "London")
        let unicodeComment = "<script>// skip\u{2028}const currentLocation = {\"localizedName\":\"London\"};</script>"
        precondition(currentAirQuality(in: unicodeComment + html)?.city == "London")
        let duplicateName = #"<script>const currentLocation = {"localizedName":"London","localizedName":"Paris"};</script>"#
        precondition(currentAirQuality(in: duplicateName + html)?.city == nil)

        let multilineLocation = """
        <script>
        let currentLocation = {
            "description": "A value containing };",
            "localizedName": "Aix-en-Provence"
        };
        </script>
        """
        precondition(currentAirQuality(in: multilineLocation + html)?.city == "Aix-en-Provence",
                     "The city must be read from multiline JSON with punctuation inside strings")

        var source = URLComponents()
        source.scheme = "https"
        source.host = "air.example.org"
        source.path = "/city"
        source.queryItems = [URLQueryItem(name: "lang", value: "ru")]
        let address = source.string!
        precondition(sourcePageURL(from: "  \(address)  ")?.absoluteString == address)
        precondition(sourcePageURL(from: nil) == nil)
        precondition(sourcePageURL(from: " ") == nil)
        precondition(sourcePageURL(from: "air.example.org/city") == nil)
        source.host = ""
        precondition(sourcePageURL(from: source.string!) == nil)
        let localFile = URL(fileURLWithPath: "/tmp/city.html")
        precondition(sourcePageURL(from: localFile.absoluteString) == nil)
        let bytes = { AsyncStream<UInt8> { stream in
            for byte: UInt8 in [65, 81, 73] { stream.yield(byte) }
            stream.finish()
        } }
        let exact = try await collectAQIBody(bytes(), limit: 3)
        let oversized = try await collectAQIBody(bytes(), limit: 2)
        precondition(exact == Data("AQI".utf8))
        precondition(oversized == nil, "A response body must be discarded when it exceeds the limit")
        print("Air quality, localized city, and source URL checks passed")
    }
}
