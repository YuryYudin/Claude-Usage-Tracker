import SwiftUI
import WidgetKit

// MARK: - Palette

/// Every color the widget draws, for the two states a macOS desktop widget is
/// displayed in: full color while the desktop is frontmost, and greyed out
/// while any other app is.
///
/// Measured against a swatch grid rendered by the real widget host, the greyed
/// state works out to `pixel = plate × luminance(color)`, and it has three
/// consequences the layout has to be built around:
///
/// - `widgetRenderingMode` stays `.fullColor` in both states, so there is no
///   environment value to branch on — one set of colors has to serve both.
/// - The alpha channel is ignored (`white.opacity(0.5)` measured a factor of
///   1.01, `black.opacity(0.5)` measured 0.23 — identical to solid black), so
///   hierarchy has to come from opaque grey levels, never from `.opacity`, and
///   hierarchical styles like `.secondary` are unusable.
/// - `containerBackground` is exempt from the multiply: the host replaces it
///   with its own light plate. A background drawn as *content* is not exempt,
///   which is what keeps the dark card dark when greyed — and with the card
///   dark, near-white text maps to the light plate value and stays readable.
///   That is why `body` paints the card in a `ZStack` and the widget disables
///   its content margins.
private struct Palette {
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }

    var card: Color { isDark ? Color(white: 0.16) : Color(white: 0.97) }
    var primary: Color { isDark ? Color(white: 0.95) : Color(white: 0.12) }
    var secondary: Color { isDark ? Color(white: 0.72) : Color(white: 0.36) }
    var tertiary: Color { isDark ? Color(white: 0.58) : Color(white: 0.50) }
    var barTrack: Color { isDark ? Color(white: 0.34) : Color(white: 0.82) }
    var separator: Color { isDark ? Color(white: 0.30) : Color(white: 0.80) }

    /// Severity hues, picked so that every one of them still contrasts with
    /// the card after the host flattens it to grey — in Dark Mode that means
    /// no deep red, which would land darker than the card it sits on.
    func usage(_ percentage: Double) -> Color {
        switch percentage {
        case ..<75:
            return isDark
                ? Color(red: 0.19, green: 0.82, blue: 0.35)
                : Color(red: 0.14, green: 0.57, blue: 0.24)
        case ..<90:
            return isDark
                ? Color(red: 1.00, green: 0.62, blue: 0.04)
                : Color(red: 0.52, green: 0.29, blue: 0.00)
        default:
            return isDark
                ? Color(red: 1.00, green: 0.41, blue: 0.38)
                : Color(red: 0.60, green: 0.09, blue: 0.09)
        }
    }
}

// MARK: - Shared helpers

/// Widget content is inset by hand because the families disable their content
/// margins — the card has to reach the widget's edges to survive greying.
private let widgetContentPadding: CGFloat = 14

private func providerIcon(_ provider: WidgetSnapshot.ProfileEntry.Provider) -> String {
    switch provider {
    case .claude: return "sparkle"
    case .codex: return "chevron.left.forwardslash.chevron.right"
    case .zai: return "z.square.fill"
    }
}

/// Drawn by hand rather than with `ProgressView`/`Gauge`: the system styles
/// draw their track with a hierarchical fill, whose greyed-out result isn't
/// controllable — an empty bar ended up looking identical to a full one.
private struct UsageBarTrack: View {
    let percentage: Double
    let fill: Color
    let track: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: proxy.size.width * CGFloat(min(max(percentage, 0), 100) / 100))
            }
        }
        .frame(height: height)
    }
}

private struct UsageRing: View {
    let percentage: Double
    let palette: Palette
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(palette.barTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percentage, 0), 100) / 100))
                .stroke(
                    palette.usage(percentage),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(percentage))%")
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(palette.primary)
        }
    }
}

private struct UsageBar: View {
    let label: LocalizedStringKey
    let percentage: Double
    let resetTime: Date?
    /// The timeline entry's date — comparisons must use it (not `Date()`)
    /// so pre-rendered future entries evaluate correctly.
    let now: Date
    let palette: Palette
    /// Compact sizing for the medium family's tight rows; the large family
    /// has room for more legible type.
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack {
                Text(label)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(palette.secondary)
                Spacer()
                Text("\(Int(percentage))%")
                    .font((compact ? Font.caption2 : .caption).monospacedDigit().bold())
                    .foregroundStyle(palette.usage(percentage))
            }
            UsageBarTrack(
                percentage: percentage,
                fill: palette.usage(percentage),
                track: palette.barTrack,
                height: compact ? 4 : 5
            )
            if let resetTime, resetTime > now {
                Text(resetTime, style: .relative)
                    .font(compact ? .system(size: 9) : .caption2)
                    .foregroundStyle(palette.tertiary)
            }
        }
    }
}

/// Shown on rows whose data has gone cold. Dimming alone can't say *why* a row
/// looks muted — this states how old the number actually is, so a profile whose
/// provider has stopped refreshing is distinguishable from one that is simply
/// idle.
private struct StaleBadge: View {
    let lastUpdated: Date
    let palette: Palette

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "clock.badge.exclamationmark")
            Text(lastUpdated, style: .relative)
        }
        .font(.system(size: 9))
        .foregroundStyle(palette.tertiary)
        .lineLimit(1)
    }
}

private struct NoDataView: View {
    let palette: Palette

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.title2)
                .foregroundStyle(palette.secondary)
            Text("widget.no_data")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondary)
        }
    }
}

/// Staleness lightens the ink instead of using `.opacity`: the greying pass
/// ignores alpha, so a dimmed row would look identical to a fresh one there.
private extension View {
    @ViewBuilder
    func staleDimmed(_ isStale: Bool, isDark: Bool) -> some View {
        if isStale {
            saturation(0.3).brightness(isDark ? -0.22 : 0.22)
        } else {
            self
        }
    }
}

// MARK: - Small widget: active profile session usage

struct SessionUsageWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: UsageEntry

    private var profile: WidgetSnapshot.ProfileEntry? {
        let profiles = entry.snapshot?.profiles ?? []
        return profiles.first(where: \.isActive)
            ?? profiles.first(where: \.isDisplayed)
            ?? profiles.first
    }

    var body: some View {
        let palette = Palette(colorScheme: colorScheme)
        ZStack {
            // Painted as content, not as the container background, so the
            // greyed-out state keeps the card dark instead of flattening it.
            palette.card
            Group {
                if let profile {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: providerIcon(profile.provider))
                                .font(.caption2)
                                .foregroundStyle(palette.secondary)
                            Text(profile.name)
                                .font(.caption.bold())
                                .lineLimit(1)
                                .foregroundStyle(palette.primary)
                        }
                        UsageRing(
                            percentage: profile.sessionPercentage,
                            palette: palette,
                            lineWidth: 9
                        )
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        Text(LocalizedStringKey(profile.primaryLabel ?? "widget.session"))
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if let sessionResetTime = profile.sessionResetTime,
                           sessionResetTime > entry.date {
                            Text(sessionResetTime, style: .relative)
                                .font(.system(size: 9))
                                .foregroundStyle(palette.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .staleDimmed(entry.isProfileStale(profile), isDark: colorScheme == .dark)
                } else {
                    NoDataView(palette: palette)
                }
            }
            .padding(widgetContentPadding)
        }
        .containerBackground(palette.card, for: .widget)
    }
}

struct SessionUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SessionUsageWidget", provider: UsageTimelineProvider()) { entry in
            SessionUsageWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.session.name"))
        .description(String(localized: "widget.session.desc"))
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

// MARK: - Medium/large widget: all display-selected profiles

struct UsageOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: UsageEntry

    private var profiles: [WidgetSnapshot.ProfileEntry] {
        let selected = (entry.snapshot?.profiles ?? []).filter(\.isDisplayed)
        return Array(selected.prefix(family == .systemLarge ? 6 : 4))
    }

    var body: some View {
        let palette = Palette(colorScheme: colorScheme)
        ZStack {
            palette.card
            Group {
                if profiles.isEmpty {
                    NoDataView(palette: palette)
                } else if family == .systemLarge {
                    largeLayout(palette)
                } else {
                    mediumLayout(palette)
                }
            }
            .padding(widgetContentPadding)
        }
        .containerBackground(palette.card, for: .widget)
    }

    /// Large: one card per profile — name as a header line, both bars at
    /// full width beneath it. Rows share the vertical space equally so the
    /// content fills the widget instead of clustering in the center.
    private func largeLayout(_ palette: Palette) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                if index > 0 {
                    // Not `Divider()`: the system separator's greyed-out
                    // result isn't controllable.
                    Rectangle()
                        .fill(palette.separator)
                        .frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(profile.name)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                            .foregroundStyle(palette.primary)
                        if profile.isActive {
                            Image(systemName: providerIcon(profile.provider))
                                .font(.caption2)
                                .foregroundStyle(palette.secondary)
                        }
                        Spacer(minLength: 0)
                        if entry.isProfileStale(profile) {
                            StaleBadge(lastUpdated: profile.lastUpdated, palette: palette)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        UsageBar(
                            label: LocalizedStringKey(profile.primaryLabel ?? "widget.session"),
                            percentage: profile.sessionPercentage,
                            resetTime: profile.sessionResetTime,
                            now: entry.date,
                            palette: palette,
                            compact: false
                        )
                        if let weeklyPercentage = profile.weeklyPercentage {
                            UsageBar(
                                label: LocalizedStringKey(profile.secondaryLabel ?? "widget.weekly"),
                                percentage: weeklyPercentage,
                                resetTime: profile.weeklyResetTime,
                                now: entry.date,
                                palette: palette,
                                compact: false
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Per-row: a profile can go stale on its own — the
                // single-profile refresh path only updates the
                // active profile.
                .staleDimmed(entry.isProfileStale(profile), isDark: colorScheme == .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Medium: one compact line per profile, name in a fixed column so the
    /// bars align across rows. Rows share the vertical space equally.
    private func mediumLayout(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(profiles) { profile in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .foregroundStyle(palette.primary)
                        if entry.isProfileStale(profile) {
                            StaleBadge(lastUpdated: profile.lastUpdated, palette: palette)
                        }
                    }
                    .frame(width: 78, alignment: .leading)
                    UsageBar(
                        label: LocalizedStringKey(profile.primaryLabel ?? "widget.session"),
                        percentage: profile.sessionPercentage,
                        resetTime: profile.sessionResetTime,
                        now: entry.date,
                        palette: palette
                    )
                    if let weeklyPercentage = profile.weeklyPercentage {
                        UsageBar(
                            label: LocalizedStringKey(profile.secondaryLabel ?? "widget.weekly"),
                            percentage: weeklyPercentage,
                            resetTime: profile.weeklyResetTime,
                            now: entry.date,
                            palette: palette
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                .staleDimmed(entry.isProfileStale(profile), isDark: colorScheme == .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct UsageOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageOverviewWidget", provider: UsageTimelineProvider()) { entry in
            UsageOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.overview.name"))
        .description(String(localized: "widget.overview.desc"))
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
