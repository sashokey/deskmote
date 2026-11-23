import AppIntents
import SwiftUI
import WidgetKit

struct ConfigureAirQuality: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Качество воздуха"

    @Parameter(title: "Source URL")
    var sourceURL: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Source URL: \(\.$sourceURL)")
    }
}

private struct AQIEntry: TimelineEntry {
    let date: Date
    let reading: AirQualityReading?
    let needsSource: Bool
}

private struct AQIProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AQIEntry {
        let pollutants = zip(pollutantNames, [19, 7, 11, 20, 3, 179]).enumerated().map { offset, item in
            PollutantReading(
                id: item.0.0,
                name: item.0.1,
                category: offset < 2 ? "Средний" : "Отличный",
                concentration: "\(item.1) µg/m³"
            )
        }
        let reading = AirQualityReading(index: 37, city: nil, category: "Средний", pollutants: pollutants)
        return AQIEntry(date: .now, reading: reading, needsSource: false)
    }

    func snapshot(for configuration: ConfigureAirQuality, in context: Context) async -> AQIEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await loadEntry(for: configuration)
    }

    func timeline(for configuration: ConfigureAirQuality, in context: Context) async -> Timeline<AQIEntry> {
        let entry = await loadEntry(for: configuration)
        let policy: TimelineReloadPolicy = entry.needsSource
            ? .never
            : .after(entry.date.addingTimeInterval(900))
        return Timeline(entries: [entry], policy: policy)
    }

    private func loadEntry(for configuration: ConfigureAirQuality) async -> AQIEntry {
        guard let url = sourcePageURL(from: configuration.sourceURL) else {
            return AQIEntry(date: .now, reading: nil, needsSource: true)
        }

        let request = URLRequest(url: url, timeoutInterval: 10)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForResource = 15
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }

        let reading: AirQualityReading?
        if let (bytes, response) = try? await session.bytes(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let data = try? await collectAQIBody(bytes, limit: 4 * 1024 * 1024) {
            reading = currentAirQuality(in: String(decoding: data, as: UTF8.self))
        } else {
            reading = nil
        }
        return AQIEntry(date: .now, reading: reading, needsSource: false)
    }
}

private struct AirQualityCard: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins
    let reading: AirQualityReading?
    let needsSource: Bool

    private let mint = Color(red: 0.61, green: 0.96, blue: 0.91)
    private let secondary = Color.white.opacity(0.90)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if family == .systemMedium, let reading {
                summary.frame(width: 101, alignment: .leading)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 3) {
                    ForEach(reading.pollutants) { pollutant in
                        pollutantTile(pollutant)
                    }
                }
            } else {
                summary
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, margins.leading)
        .padding(.trailing, margins.trailing)
        .padding(.vertical, 6)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.15, blue: 0.24), Color(red: 0.04, green: 0.29, blue: 0.31)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(reading?.city ?? "Качество воздуха")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let reading {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reading.index.formatted())
                        .font(.system(size: 43, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.65)
                    Text("AQI")
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize()
                }
                .lineLimit(1)
                .foregroundStyle(mint)
                .widgetAccentable()
                .accessibilityElement(children: .combine)

                if let category = reading.category {
                    Text(category)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                }
            } else {
                Text(needsSource ? "Укажите URL источника" : "Нет данных")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(secondary)
            }
        }
    }

    private func pollutantTile(_ pollutant: PollutantReading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pollutant.name)
                .font(.system(size: 14, weight: .semibold))
            Text(pollutant.concentration?.replacingOccurrences(of: "µg/m³", with: "мкг/м³") ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(secondary)
            Text(pollutant.category ?? "Нет данных")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

struct AirQualityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "SaintPetersburgAirQuality",
            intent: ConfigureAirQuality.self,
            provider: AQIProvider()
        ) { entry in
            AirQualityCard(reading: entry.reading, needsSource: entry.needsSource)
        }
        .configurationDisplayName("Качество воздуха")
        .description("Текущий AQI и уровни загрязняющих веществ.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
