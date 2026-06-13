import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Weekly Digest (#208)
//
// A deterministic, offline "week in review". Reads the local DailyMetric history
// from the Repository, pulls each tracked metric into a day→value map, and feeds
// WeeklyDigestEngine (pure, in StrandAnalytics) to produce a Monday-anchored
// summary: per-metric this-week mean + week-over-week delta + vs-baseline, the
// biggest movers, a strain-vs-recovery balance read, and 1–2 plain-English focal
// points. No AI, no network — the engine is fully deterministic and unit-tested.
//
// Two surfaces are exposed so the orchestrator can wire whichever it wants:
//   • `WeeklyDigestCard` — an embeddable card (drop into Today / Trends).
//   • `WeeklyDigestView` — a full ScreenScaffold screen (for a sidebar `.digest`
//      case). Both share `WeeklyDigestContent`, so they never drift.
//
// Framing is informational and non-clinical, consistent with the app DISCLAIMER.

// MARK: - Shared digest builder (pure glue over the engine)

enum WeeklyDigestSource {

    /// Build the digest for the week containing today's local day from a DailyMetric
    /// history. Extracts each tracked metric into a "yyyy-MM-dd"→value map and hands
    /// it to the pure engine.
    static func digest(from days: [DailyMetric],
                       anchorDay: String) -> WeeklyDigest {
        var charge: [String: Double] = [:]
        var effort: [String: Double] = [:]
        var rest: [String: Double] = [:]
        var rhr: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        for d in days {
            if let v = d.recovery { charge[d.day] = v }
            if let v = d.strain   { effort[d.day] = v }
            // Rest = the sleep-performance composite, recomputed on the persisted day.
            if let r = restScore(for: d) { rest[d.day] = r }
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.avgHrv    { hrv[d.day] = v }
        }
        return WeeklyDigestEngine.build(
            byMetric: [.charge: charge, .effort: effort, .rest: rest, .rhr: rhr, .hrv: hrv],
            anchorDay: anchorDay)
    }

    /// The 0–100 Rest composite for a persisted day, via AnalyticsEngine's display-path
    /// helper (duration-vs-need / efficiency / restorative / consistency). Returns nil
    /// for a day with no in-bed sleep / missing efficiency, so non-sleep days are simply
    /// absent from the Rest series.
    private static func restScore(for d: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: d)
    }
}

// MARK: - Embeddable card

/// The weekly digest as a single card (for Today / Trends). Renders nothing
/// (an empty view) when there's no data this week, so it's safe to always place.
struct WeeklyDigestCard: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
        if digest.isEmpty {
            EmptyView()
        } else {
            NoopCard {
                WeeklyDigestContent(digest: digest, compact: true)
            }
        }
    }
}

// MARK: - Full screen

/// The weekly digest as a full screen (for a sidebar `.digest` case).
struct WeeklyDigestView: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Week in review",
                       subtitle: "Your Monday-to-Sunday, read in one glance.") {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "A weekly digest needs a few days of history. Wear your strap or import your WHOOP export in Data Sources."
                    : "Loading your history…")
            } else {
                let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
                if digest.isEmpty {
                    DataPendingNote(
                        title: "No readings this week yet",
                        message: "Once this week has a day or two of data, your week-in-review appears here.")
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        NoopCard { WeeklyDigestContent(digest: digest, compact: false) }
                    }
                }
            }
        }
    }
}

// MARK: - Shared content

/// The inner content shared by the card and the full screen. `compact` trims the
/// metric grid to the headline rows for the card; the full screen shows everything.
struct WeeklyDigestContent: View {
    let digest: WeeklyDigest
    var compact: Bool = false

    /// Display order: the two daily scores first, then the nightly signals.
    private static let order: [WeeklyMetric] = [.charge, .effort, .rest, .hrv, .rhr]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Focal points — the plain-English read, most salient first.
            if !digest.focalPoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(digest.focalPoints.enumerated()), id: \.offset) { _, line in
                        focalRow(line)
                    }
                }
            }

            Divider().overlay(StrandPalette.hairline)

            // Per-metric rows.
            VStack(spacing: 10) {
                ForEach(rows, id: \.metric.rawValue) { row in
                    metricRow(row)
                }
            }

            if !compact { footer }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Week in review").strandOverline()
                Text(weekRangeLabel)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            Text("\(digest.daysWithData)/7 days")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityLabel("\(digest.daysWithData) of 7 days had data this week")
        }
    }

    // MARK: Focal row

    private func focalRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(line)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
    }

    // MARK: Metric row

    private var rows: [WeeklyMetricSummary] {
        let visible = compact ? [WeeklyMetric.charge, .effort, .rest] : Self.order
        return visible.compactMap { digest.summary($0) }
    }

    private func metricRow(_ s: WeeklyMetricSummary) -> some View {
        HStack(spacing: 12) {
            // Label.
            Text(s.metric.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 92, alignment: .leading)

            // This-week mean.
            Text(meanText(s))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 56, alignment: .leading)

            Spacer(minLength: 8)

            // Week-over-week delta chip (color-coded by good/bad, not just up/down).
            deltaChip(s)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibility(s))
    }

    private func deltaChip(_ s: WeeklyMetricSummary) -> some View {
        let tone = chipTone(s)
        let arrow = s.wowDelta > 0 ? "arrow.up" : (s.wowDelta < 0 ? "arrow.down" : "minus")
        return HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(deltaText(s))
                .font(StrandFont.captionNumber)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.opacity(0.12), in: Capsule())
    }

    // MARK: Footer (full screen only)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(StrandPalette.hairline)
            if let sd = digest.sleepConsistencySD {
                Text("Sleep steadiness: Rest varied ±\(fmt1(sd)) pts night to night.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(digest.balance.sentence)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Informational only — not medical advice.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Formatting

    private var weekRangeLabel: String {
        "\(shortDate(digest.weekStart)) – \(shortDate(digest.weekEnd))"
    }

    /// "Jun 8" from "2026-06-08", via the engine's own pure parse (no Calendar).
    private func shortDate(_ ymd: String) -> String {
        guard let (_, m, d) = WeeklyDigestEngine.parseYMD(ymd) else { return ymd }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let name = (1...12).contains(m) ? months[m - 1] : "\(m)"
        return "\(name) \(d)"
    }

    private func meanText(_ s: WeeklyMetricSummary) -> String {
        guard s.thisWeek.n > 0 else { return "—" }
        let v = Int(s.thisWeek.mean.rounded())
        return s.metric.unit.isEmpty ? "\(v)" : "\(v) \(s.metric.unit)"
    }

    private func deltaText(_ s: WeeklyMetricSummary) -> String {
        guard s.weekOverWeek.current.n > 0, s.weekOverWeek.previous.n > 0 else { return "new" }
        if let pct = s.weekOverWeek.pctChange, abs(pct) >= 1 {
            return "\(Int(abs(pct).rounded()))%"
        }
        return fmt1(abs(s.wowDelta))
    }

    /// Tone: good moves green, bad moves rose, flat/uncomparable grey — folding in
    /// each metric's `higherIsBetter` so a Resting-HR rise reads as a warning.
    private func chipTone(_ s: WeeklyMetricSummary) -> Color {
        switch s.wowGoodness {
        case 1:  return StrandPalette.statusPositive
        case -1: return StrandPalette.statusCritical
        default: return StrandPalette.textTertiary
        }
    }

    private func rowAccessibility(_ s: WeeklyMetricSummary) -> String {
        let mean = meanText(s)
        guard s.weekOverWeek.current.n > 0, s.weekOverWeek.previous.n > 0 else {
            return "\(s.metric.label): \(mean) this week, no comparison."
        }
        let dir = s.wowDelta > 0 ? "up" : (s.wowDelta < 0 ? "down" : "unchanged")
        let frame = s.wowGoodness == 1 ? ", a good sign" : (s.wowGoodness == -1 ? ", worth a look" : "")
        return "\(s.metric.label): \(mean) this week, \(dir) \(deltaText(s)) week over week\(frame)."
    }

    private func fmt1(_ x: Double) -> String { String(format: "%.1f", x) }
}

#if DEBUG
private func previewDigest() -> WeeklyDigest {
    var charge: [String: Double] = [:], effort: [String: Double] = [:]
    var rest: [String: Double] = [:], hrv: [String: Double] = [:], rhr: [String: Double] = [:]
    // This week (Mon 2026-06-08 .. Sun 2026-06-14) trending up; last week lower.
    for (i, day) in (8...14).enumerated() {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 62 + Double(i) * 3
        effort[k] = 70 - Double(i)
        rest[k] = 82 + Double(i % 3)
        hrv[k] = 58 + Double(i)
        rhr[k] = 53 - Double(i % 2)
    }
    for day in 1...7 {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 55; effort[k] = 64; rest[k] = 80; hrv[k] = 52; rhr[k] = 55
    }
    return WeeklyDigestEngine.build(
        byMetric: [.charge: charge, .effort: effort, .rest: rest, .hrv: hrv, .rhr: rhr],
        anchorDay: "2026-06-13")
}

#Preview("Weekly digest – card") {
    NoopCard { WeeklyDigestContent(digest: previewDigest(), compact: true) }
        .padding(24)
        .frame(width: 420)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}

#Preview("Weekly digest – full") {
    ScrollView {
        NoopCard { WeeklyDigestContent(digest: previewDigest(), compact: false) }
            .padding(24)
    }
    .frame(width: 520, height: 680)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
