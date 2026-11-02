import Foundation
import SwiftUI

/// Blocks preserve their real duration; compact headers provide another way to
/// reach very short, overlapping, all-day, and overnight appointments.
struct AgendaTimeline: View {
    let items: [AgendaItem]
    let date: Date
    var compact = false
    var onSelect: ((AgendaItem) -> Void)? = nil

    private var calendar: Calendar { AgendaClock.calendar }
    private let firstHour = 7
    private let lastHour = 23
    private var gutter: CGFloat { compact ? 25 : 37 }
    private var columnGap: CGFloat { compact ? 6 : 12 }

    private var days: [Date] {
        let today = calendar.startOfDay(for: date)
        return [today, calendar.date(byAdding: .day, value: 1, to: today) ?? today]
    }

    var body: some View {
        VStack(spacing: compact ? 7 : 13) {
            HStack(alignment: .top, spacing: columnGap) {
                Color.clear.frame(width: max(0, gutter - columnGap), height: 1)
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    dayHeader(day, title: index == 0 ? "Hoy" : "Mañana")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if days.contains(where: { !allDayItems(on: $0).isEmpty }) {
                HStack(alignment: .top, spacing: columnGap) {
                    Color.clear.frame(width: max(0, gutter - columnGap), height: 1)
                    ForEach(days, id: \.self) { day in
                        eventSummary(allDayItems(on: day), empty: " ", prefix: "Todo el día")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            GeometryReader { geometry in
                let height = max(1, geometry.size.height)
                let availableWidth = max(1, geometry.size.width - gutter - columnGap)
                let columnWidth = availableWidth / 2
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: firstHour, through: lastHour, by: compact ? 2 : 1)), id: \.self) { hour in
                        let y = fraction(for: hour) * height
                        Rectangle()
                            .fill(Color.primary.opacity(hour % 2 == 1 ? 0.08 : 0.035))
                            .frame(width: max(1, geometry.size.width - gutter), height: 0.5)
                            .offset(x: gutter, y: y)
                        if compact || hour % 2 == 1 {
                            Text(String(format: "%02d", hour))
                                .font(compact ? .system(size: 10, weight: .regular, design: .rounded) : .caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: gutter - 7, alignment: .trailing)
                                .offset(y: min(max(y - 6, 0), max(0, height - 12)))
                        }
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        dayColumn(day, width: columnWidth, height: height)
                            .frame(width: columnWidth, height: height)
                            .offset(x: gutter + CGFloat(index) * (columnWidth + columnGap))
                    }
                }
            }

            if days.contains(where: { !outsideItems(on: $0).isEmpty }) {
                HStack(alignment: .top, spacing: columnGap) {
                    Color.clear.frame(width: max(0, gutter - columnGap), height: 1)
                    ForEach(days, id: \.self) { day in
                        let outside = outsideItems(on: day)
                        eventSummary(outside, empty: " ", prefix: "Fuera de 07–23 h")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agenda de hoy y mañana, de siete a veintitrés. Los bloques de color son citas. Revisa también los eventos de todo el día.")
    }

    @ViewBuilder
    private func dayHeader(_ day: Date, title: String) -> some View {
        let events = dayItems(on: day)
        if let onSelect, !events.isEmpty {
            Menu {
                ForEach(events) { item in
                    Button(accessibleLabel(for: item)) { onSelect(item) }
                }
            } label: {
                headerLabel(day, title: title, menu: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + ", " + String(events.count) + " citas. Ver todas")
        } else {
            headerLabel(day, title: title, menu: false)
        }
    }

    private func headerLabel(_ day: Date, title: String, menu: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                if menu { Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary) }
            }
            Text(day.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "es_ES"))))
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: compact ? 30 : 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func eventSummary(_ events: [AgendaItem], empty: String, prefix: String) -> some View {
        if events.isEmpty {
            Text(empty).font(compact ? .caption2 : .caption)
        } else if let onSelect {
            Menu {
                ForEach(events) { item in
                    Button(accessibleLabel(for: item)) { onSelect(item) }
                }
            } label: {
                summaryLabel(events, prefix: prefix)
                    .frame(minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(prefix + ": " + events.map(\.title).joined(separator: ", ") + ". Ver citas")
        } else {
            Link(destination: eventURL(for: events[0])) {
                summaryLabel(events, prefix: prefix)
            }
            .accessibilityLabel(prefix + ": " + events.map(\.title).joined(separator: ", "))
        }
    }

    private func summaryLabel(_ events: [AgendaItem], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prefix).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle().fill(AgendaBlockColor.color(hex: events[0].colorHex)).frame(width: 5, height: 5)
                Text((events[0].title.isEmpty ? "Sin título" : events[0].title) + (events.count > 1 ? " +\(events.count - 1)" : ""))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .font(compact ? .system(size: 10) : .caption)
    }

    @ViewBuilder
    private func dayColumn(_ day: Date, width: CGFloat, height: CGFloat) -> some View {
        let positions = AgendaMath.layout(on: day, events: items, startHour: firstHour, endHour: lastHour, calendar: calendar)
        let window = AgendaMath.window(for: day, startHour: firstHour, endHour: lastHour, calendar: calendar)
        let allDayBusy = allDayItems(on: day).contains(where: \.blocksTime)
        ZStack(alignment: .topLeading) {
            // Very light sections distinguish morning, afternoon, and evening.
            Rectangle().fill(Color.primary.opacity(0.018))
                .frame(width: width, height: (fraction(for: 18) - fraction(for: 12)) * height)
                .offset(y: fraction(for: 12) * height)
                .accessibilityHidden(true)
            if allDayBusy {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.055))
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
            }
            ForEach(positions) { positioned in
                let gap: CGFloat = 2
                let laneCount = max(1, positioned.laneCount)
                let laneWidth = max(1, (width - CGFloat(laneCount - 1) * gap) / CGFloat(laneCount))
                let blockHeight = max(0.7, CGFloat(positioned.endFraction - positioned.startFraction) * height)
                eventControl(positioned.event, width: laneWidth, height: blockHeight)
                    .frame(width: laneWidth, height: blockHeight)
                    .offset(x: CGFloat(positioned.lane) * (laneWidth + gap), y: CGFloat(positioned.startFraction) * height)
            }
            if calendar.isDate(date, inSameDayAs: day), date >= window.start, date < window.end {
                let currentY = CGFloat(date.timeIntervalSince(window.start) / window.duration) * height
                Rectangle().fill(Color.red).frame(width: width, height: 1).offset(y: currentY)
                    .accessibilityHidden(true)
                Circle().fill(Color.red).frame(width: 4, height: 4).offset(x: -2, y: currentY - 1.5)
                    .accessibilityHidden(true)
            }
            if positions.isEmpty {
                Text(allDayBusy ? "Ocupado todo el día" : "Libre")
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    @ViewBuilder
    private func eventControl(_ item: AgendaItem, width: CGFloat, height: CGFloat) -> some View {
        if let onSelect {
            Button { onSelect(item) } label: { eventBlock(item, width: width, height: height) }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibleLabel(for: item))
        } else {
            Link(destination: eventURL(for: item)) { eventBlock(item, width: width, height: height) }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibleLabel(for: item))
        }
    }

    private func eventBlock(_ item: AgendaItem, width: CGFloat, height: CGFloat) -> some View {
        let color = AgendaBlockColor.color(hex: item.colorHex)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: compact ? 3 : 5)
                .fill(color.opacity(item.blocksTime ? 0.2 : 0.045))
            if !item.blocksTime {
                RoundedRectangle(cornerRadius: compact ? 3 : 5)
                    .strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: compact ? 2 : 3)
            if height >= (compact ? 16 : 20), width >= 35 {
                VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                    Text(item.title.isEmpty ? "Sin título" : item.title)
                        .font(compact ? .system(size: 11, weight: .medium) : .subheadline.weight(.medium))
                        .lineLimit(height >= (compact ? 42 : 65) ? 2 : 1)
                    if height >= (compact ? 38 : 51) {
                        Text(timeRange(for: item))
                            .font(compact ? .system(size: 10) : .caption)
                            .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !item.blocksTime, height >= (compact ? 60 : 85) {
                        Text("No bloquea").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, compact ? 5 : 8)
                .padding(.top, compact ? 2 : 4)
            }
        }
        .frame(width: width, height: height).clipped().contentShape(Rectangle())
    }

    private func dayItems(on day: Date) -> [AgendaItem] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return items.filter { $0.start < end && $0.end > start }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    private func allDayItems(on day: Date) -> [AgendaItem] { dayItems(on: day).filter(\.isAllDay) }

    private func outsideItems(on day: Date) -> [AgendaItem] {
        let window = AgendaMath.window(for: day, startHour: firstHour, endHour: lastHour, calendar: calendar)
        return dayItems(on: day).filter { !$0.isAllDay && ($0.start < window.start || $0.end > window.end) }
    }

    private func fraction(for hour: Int) -> CGFloat { CGFloat(hour - firstHour) / CGFloat(lastHour - firstHour) }

    private func timeRange(for item: AgendaItem) -> String {
        if item.isAllDay { return "Todo el día" }
        let start = AgendaClock.timeString(item.start)
        let end = AgendaClock.timeString(item.end)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.start), to: calendar.startOfDay(for: item.end)).day ?? 0
        let suffix = days > 0 ? " (+\(days) \(days == 1 ? "día" : "días"))" : ""
        return start + "–" + end + suffix
    }

    private func accessibleLabel(for item: AgendaItem) -> String {
        (item.title.isEmpty ? "Sin título" : item.title) + ", " + timeRange(for: item) + (item.blocksTime ? "" : ", no bloquea tiempo")
    }

    private func eventURL(for item: AgendaItem) -> URL {
        var components = URLComponents()
        components.scheme = "miagenda"
        components.host = "event"
        components.queryItems = [URLQueryItem(name: "id", value: item.id)]
        return components.url ?? URL(string: "miagenda://today")!
    }
}

private enum AgendaBlockColor {
    static func color(hex: String) -> Color {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return .blue }
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}
