import StorageSyncCore
import SwiftUI

/// Local and cloud storage share one scale across two bars. The destination
/// combines its existing bytes with the yellow pending segment; the three
/// colors are explained by a legend or a hover tooltip.
struct StorageBalanceView: View {
    enum Style {
        case full
        case compact
        case barsOnly
    }

    let reading: BalanceReading
    var style: Style = .full
    /// Drives the sweep on the pending segment. Nothing repeats when this is false.
    var isTransferring = false

    @Environment(\.colorScheme) private var colorScheme

    private var balance: StorageBalance { reading.balance }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .full ? 7 : 4) {
            bars
            if style != .barsOnly {
                legend
                caption
            }
        }
        // Snapshots arrive once a second, so the bars are told to glide between
        // samples rather than step. Anything faster reads as flicker on a sync
        // that is moving many small files.
        .animation(.easeInOut(duration: 0.6), value: reading)
        .opacity(reading.isCurrent ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage balance")
    }

    // MARK: - Rows

    @ViewBuilder
    private var legend: some View {
        if style == .compact {
            // The menu's text column is narrower than the whole popover.
            // Short place names keep all three keys on one line below the bars.
            HStack(spacing: 10) {
                ForEach(Line.allCases) { legendEntry(for: $0) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    ForEach(Line.allCases) { legendEntry(for: $0) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Line.allCases) { legendEntry(for: $0) }
                }
            }
        }
    }

    private func legendEntry(for line: Line) -> some View {
        HStack(spacing: 5) {
            label(for: line)
            if style == .full {
                value(for: line)
            }
        }
        .fixedSize()
        .help(help(for: line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: line))
        .accessibilityValue(bytes(for: line).formattedByteCount)
    }

    private var bars: some View {
        VStack(spacing: rowSpacing) {
            ForEach([Line.local, .cloud]) { bar(for: $0) }
        }
        .overlay { frontier }
    }

    private func label(for line: Line) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol(for: line))
                .font(.system(size: 11))
                .foregroundStyle(color(for: line))
                .frame(width: 13)
            Text(legendTitle(for: line))
                .lineLimit(1)
        }
        .font(style == .full ? .caption : .caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func value(for line: Line) -> some View {
        Text(bytes(for: line).formattedByteCount)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private func bar(for line: Line) -> some View {
        let isDestination = balance.direction == .upload ? line == .cloud : line == .local
        return GeometryReader { proxy in
            let filled = max(0, proxy.size.width * fraction(for: line))
            let pending = max(0, proxy.size.width * balance.pendingFraction)
            ZStack(alignment: alignment(for: line)) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Rectangle()
                    .fill(color(for: line))
                    .frame(width: filled)
                if isDestination {
                    Rectangle()
                        .fill(color(for: .sync))
                        .frame(width: pending)
                        .overlay(alignment: .leading) {
                            if isTransferring, balance.hasPendingWork {
                                SweepingHighlight(width: pending)
                            }
                        }
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: barHeight)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
        }
        .frame(height: rowHeight)
        .help(style == .barsOnly ? storageTooltip : isDestination ? "\(help(for: line)) · \(help(for: .sync))" : help(for: line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: line))
        .accessibilityValue(
            "\(bytes(for: line).formattedByteCount), \(percentage(for: line)) percent of everything"
                + (isDestination ? ", \(help(for: .sync))" : "")
        )
    }

    private var storageTooltip: String {
        var lines = Line.allCases.map { "\(title(for: $0)): \(bytes(for: $0).formattedByteCount)" }
        if isTransferring, balance.runBytes > 0 { lines.append(runProgress) }
        if !reading.isCurrent, let asOf = reading.asOf {
            lines.append("Last checked \(asOf.formatted(date: .abbreviated, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }

    /// The boundary the sync is working at: where the destination's fill ends
    /// and the waiting work begins. It is the only thing on screen that moves
    /// while a transfer runs, and it lines the two rows up as one reading.
    @ViewBuilder
    private var frontier: some View {
        if balance.hasPendingWork, balance.totalBytes > 0 {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 1)
                    .offset(x: proxy.size.width * (1 - balance.pendingFraction))
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Caption

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary)
                .lineLimit(style == .full ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
            // The bars answer "where is everything"; a long copy also wants
            // "how far into this batch am I", which a sliver of a full library
            // cannot show. Only while something is actually moving.
            if style == .full, isTransferring, balance.runBytes > 0 {
                Text(runProgress)
            }
            if !reading.isCurrent, let asOf = reading.asOf {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text("Last checked ")
                        + Text(asOf, format: .relative(presentation: .named))
                }
            }
        }
        .font(style == .full ? .caption : .caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    /// "2.1 GB of 9.4 GB · 23%" — this batch seen from the inside.
    private var runProgress: String {
        let percent = Int((balance.runFraction * 100).rounded())
        return "\(balance.movedBytes.formattedByteCount) of \(balance.runBytes.formattedByteCount) copied · \(percent)%"
    }

    private var summary: String {
        guard balance.totalBytes > 0 else { return "Nothing here yet" }
        let isUpload = balance.direction == .upload
        if style == .compact {
            if isTransferring, balance.runBytes > 0 { return runProgress }
            guard balance.hasPendingWork else {
                return "\(balance.totalBytes.formattedByteCount) · \(balance.localFiles.formatted()) files"
            }
            return "\(balance.pendingBytes.formattedByteCount) left of \(balance.totalBytes.formattedByteCount)"
        }
        // The three numbers the product promises — found, already at the far
        // end, still to copy — which is what the Inventory section used to say.
        return [
            "\(balance.localFiles.formatted()) files \(isUpload ? "here" : "in S3")",
            "\(balance.sharedFiles.formatted()) already \(isUpload ? "in S3" : "here")",
            "\(balance.pendingFiles.formatted()) left to \(isUpload ? "upload" : "download")"
        ].joined(separator: " · ")
    }

    // MARK: - Lines

    private enum Line: CaseIterable, Identifiable {
        case local
        case sync
        case cloud

        var id: Self { self }
    }

    private func title(for line: Line) -> String {
        switch line {
        case .local: "On this Mac"
        case .sync where !balance.hasPendingWork: "Nothing waiting"
        case .sync: balance.direction == .upload ? "Uploading" : "Downloading"
        case .cloud: "In the cloud"
        }
    }

    private func legendTitle(for line: Line) -> String {
        guard style == .compact else { return title(for: line) }
        switch line {
        case .local: return "Mac"
        case .cloud: return "Cloud"
        case .sync: return title(for: line)
        }
    }

    private func symbol(for line: Line) -> String {
        switch line {
        case .local: "internaldrive"
        case .sync where !balance.hasPendingWork: "checkmark.circle"
        case .sync: balance.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .cloud: "cloud"
        }
    }

    /// Fixed hues rather than the accent colour: a user whose accent is green
    /// would otherwise see two of the three legend entries claim to be the same thing.
    private func color(for line: Line) -> Color {
        switch line {
        case .local: Color(nsColor: .systemGreen)
        // System yellow is washed out on a white sheet, and orange already
        // means "waiting on something" everywhere else in this app.
        case .sync: colorScheme == .dark
            ? Color(nsColor: .systemYellow)
            : Color(red: 0.85, green: 0.62, blue: 0.04)
        case .cloud: Color(nsColor: .systemBlue)
        }
    }

    private func bytes(for line: Line) -> Int64 {
        switch line {
        case .local: balance.localBytes
        case .sync: balance.pendingBytes
        case .cloud: balance.cloudBytes
        }
    }

    private func fraction(for line: Line) -> Double {
        switch line {
        case .local: balance.localFraction
        case .sync: balance.pendingFraction
        case .cloud: balance.cloudFraction
        }
    }

    private func percentage(for line: Line) -> Int {
        Int((fraction(for: line) * 100).rounded())
    }

    /// The destination fills from the left; the source and the waiting work are
    /// pinned to the right. Reversing an upload's roles for a download keeps
    /// one rule on screen: the growing side always grows rightward.
    private func alignment(for line: Line) -> Alignment {
        let isDestination = balance.direction == .upload ? line == .cloud : line == .local
        return isDestination ? .leading : .trailing
    }

    private func help(for line: Line) -> String {
        switch line {
        case .local:
            "\(balance.localBytes.formattedByteCount) on this Mac · \(balance.localFiles.formatted()) files"
        case .sync:
            balance.hasPendingWork
                ? "\(balance.pendingBytes.formattedByteCount) still to copy · \(balance.pendingFiles.formatted()) files"
                : "Nothing waiting to be copied"
        case .cloud:
            "\(balance.cloudBytes.formattedByteCount) in the bucket · \(balance.cloudFiles.formatted()) objects"
        }
    }

    // MARK: - Metrics

    private var barHeight: CGFloat { style == .compact ? 4 : 8 }
    private var rowHeight: CGFloat { style == .compact ? 4 : 16 }
    private var rowSpacing: CGFloat { style == .compact ? 3 : 5 }
}

/// A highlight that crosses the pending segment while bytes are actually moving, so
/// a sync that is working looks different from one that is merely behind.
private struct SweepingHighlight: View {
    let width: CGFloat

    @State private var hasStarted = false

    var body: some View {
        let sweepWidth = max(20, width * 0.3)
        LinearGradient(
            colors: [.clear, .white.opacity(0.5), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: sweepWidth)
        .offset(x: hasStarted ? width : -sweepWidth)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                hasStarted = true
            }
        }
        .allowsHitTesting(false)
    }
}
