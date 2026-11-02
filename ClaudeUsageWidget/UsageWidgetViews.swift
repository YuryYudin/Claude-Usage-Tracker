import SwiftUI
import WidgetKit

// MARK: - Palette

/// Full-color widgets retain the contrast palette used by older desktop hosts.
/// In accented/vibrant modes the host recolors foreground shapes, including an
/// opaque content background. Keep that background out of the foreground and
/// use alpha for hierarchy so it cannot flatten the whole widget to one plate.
private struct Palette {
    let colorScheme: ColorScheme
    let renderingMode: WidgetRenderingMode

    var isFullColor: Bool { renderingMode == .fullColor }

    private var isDark: Bool { colorScheme == .dark }

    var card: Color { isDark ? Color(white: 0.16) : Color(white: 0.97) }
    var primary: Color { isFullColor ? (isDark ? Color(white: 0.95) : Color(white: 0.12)) : Color.primary.opacity(1) }
    var secondary: Color { isFullColor ? (isDark ? Color(white: 0.72) : Color(white: 0.36)) : Color.primary.opacity(0.72) }
    var tertiary: Color { isFullColor ? (isDark ? Color(white: 0.58) : Color(white: 0.50)) : Color.primary.opacity(0.58) }
    var barTrack: Color { isFullColor ? (isDark ? Color(white: 0.34) : Color(white: 0.82)) : Color.primary.opacity(0.22) }
    var separator: Color { isFullColor ? (isDark ? Color(white: 0.30) : Color(white: 0.80)) : Color.primary.opacity(0.20) }

    /// Severity hues, picked so that every one of them still contrasts with
    /// the card after the host flattens it to grey — in Dark Mode that means
    /// no deep red, which would land darker than the card it sits on.
    func usage(_ percentage: Double) -> Color {
        guard isFullColor else { return .primary }
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
/// margins. The full-color card must reach the widget's edges.
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
                    .widgetAccentable()
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
                .widgetAccentable()
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
                    .widgetAccentable()
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

/// Older full-color hosts use opaque ink levels; tinted hosts preserve alpha.
private extension View {
    @ViewBuilder
    func staleDimmed(_ isStale: Bool, isDark: Bool, renderingMode: WidgetRenderingMode) -> some View {
        if isStale && renderingMode != .fullColor {
            opacity(0.65)
        } else if isStale {
            saturation(0.3).brightness(isDark ? -0.22 : 0.22)
        } else {
            self
        }
    }
}

// MARK: - Small widget: active profile session usage

struct SessionUsageWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: UsageEntry

    private var profile: WidgetSnapshot.ProfileEntry? {
        let profiles = entry.snapshot?.profiles ?? []
        return profiles.first(where: \.isActive)
            ?? profiles.first(where: \.isDisplayed)
            ?? profiles.first
    }

    var body: some View {
        let palette = Palette(colorScheme: colorScheme, renderingMode: renderingMode)
        ZStack {
            if palette.isFullColor {
                palette.card
            }
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
                    .staleDimmed(entry.isProfileStale(profile), isDark: colorScheme == .dark, renderingMode: renderingMode)
                } else {
                    NoDataView(palette: palette)
                }
            }
            .padding(widgetContentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Overview widget: display-selected profiles

struct UsageOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: UsageEntry

    private var profiles: [WidgetSnapshot.ProfileEntry] {
        let selected = (entry.snapshot?.profiles ?? []).filter(\.isDisplayed)
        return Array(selected.prefix(family == .systemMedium ? 4 : 6))
    }

    var body: some View {
        let palette = Palette(colorScheme: colorScheme, renderingMode: renderingMode)
        ZStack {
            if palette.isFullColor {
                palette.card
            }
            Group {
                if profiles.isEmpty {
                    NoDataView(palette: palette)
                } else if family == .systemExtraLarge {
                    extraLargeLayout(palette)
                } else if family == .systemLarge && profiles.count <= 3 {
                    largeLayout(palette)
                } else {
                    // Four to six detailed cards exceed a large widget's height.
                    // Keep every account visible by aligning compact quota columns.
                    mediumLayout(palette)
                }
            }
            .padding(widgetContentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                detailedProfile(profile, palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Extra-large: two equal columns and up to three rows. This gives six
    /// accounts room for names, both quota bars, resets, and stale indicators.
    private func extraLargeLayout(_ palette: Palette) -> some View {
        VStack(spacing: 8) {
            ForEach(0..<((profiles.count + 1) / 2), id: \.self) { row in
                if row > 0 {
                    Rectangle().fill(palette.separator).frame(height: 1)
                }
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(profiles.dropFirst(row * 2).prefix(2))) { profile in
                        detailedProfile(profile, palette: palette)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if row * 2 + 1 == profiles.count {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailedProfile(_ profile: WidgetSnapshot.ProfileEntry, palette: Palette) -> some View {
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
        .staleDimmed(entry.isProfileStale(profile), isDark: colorScheme == .dark, renderingMode: renderingMode)
    }

    /// Medium and dense large: one compact line per profile, name in a fixed column so the
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
                .staleDimmed(entry.isProfileStale(profile), isDark: colorScheme == .dark, renderingMode: renderingMode)
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
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}
