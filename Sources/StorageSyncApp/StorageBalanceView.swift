import StorageSyncCore
import SwiftUI

/// Where a sync's bytes are, as three lines that share one horizontal scale.
///
///     On this Mac  ··············▓▓▓▓▓▓▓▓▓▓
///     Uploading    ··················▓▓▓▓▓▓
///     In the cloud ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓······
///                  └only in cloud┘└both┘└to go┘
///
/// The bars are not three independent percentages stacked up. They are one
/// picture: the destination fills from the left, the source is pinned to the
/// right, and the middle line covers exactly the span the destination has not
/// reached — because `StorageBalance` guarantees destination + pending is the
/// whole width. Copying a file moves the boundary rightward through all three
/// rows at once, which is what the hairline is there to make visible.
///
/// Lengths are storage, never file counts. The counts are true but they are
/// not the question being asked: 200 raw photos and 200 thumbnails are the
/// same number and nothing like the same amount of waiting.
struct StorageBalanceView: View {
    enum Style {
        case full
        case compact
    }

    let reading: BalanceReading
    var style: Style = .full
    /// Drives the sweep on the middle line. Nothing repeats when this is false.
    var isTransferring = false

    @Environment(\.colorScheme) private var colorScheme

    private var balance: StorageBalance { reading.balance }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .full ? 7 : 4) {
            if style == .full {
                labelledBars
            } else {
                bars
            }
            caption
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

    private var labelledBars: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(Line.allCases) { label(for: $0) }
            }
            bars
            VStack(alignment: .trailing, spacing: rowSpacing) {
                ForEach(Line.allCases) { value(for: $0) }
            }
        }
    }

    private var bars: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Line.allCases) { bar(for: $0) }
        }
        .overlay { frontier }
    }

    private func label(for line: Line) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol(for: line))
                .font(.system(size: 11))
                .foregroundStyle(color(for: line))
                .frame(width: 13)
            Text(title(for: line))
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: rowHeight)
        .accessibilityHidden(true)
    }

    private func value(for line: Line) -> some View {
        Text(bytes(for: line).formattedByteCount)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: rowHeight)
            .accessibilityHidden(true)
    }

    private func bar(for line: Line) -> some View {
        GeometryReader { proxy in
            let filled = max(0, proxy.size.width * fraction(for: line))
            ZStack(alignment: alignment(for: line)) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color(for: line))
                    .frame(width: filled)
                    .overlay(alignment: .leading) {
                        // Only ever built while a transfer is running. Removing
                        // the view is what stops the repeating animation.
                        if line == .sync, isTransferring, balance.hasPendingWork {
                            SweepingHighlight(width: filled)
                        }
                    }
                    .clipShape(Capsule())
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity)
        }
        .frame(height: rowHeight)
        .help(help(for: line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: line))
        .accessibilityValue(
            "\(bytes(for: line).formattedByteCount), \(percentage(for: line)) percent of everything"
        )
    }

    /// The boundary the sync is working at: where the destination's fill ends
    /// and the waiting work begins. It is the only thing on screen that moves
    /// while a transfer runs, and it lines the three rows up as one reading.
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

    private func symbol(for line: Line) -> String {
        switch line {
        case .local: "internaldrive"
        case .sync where !balance.hasPendingWork: "checkmark.circle"
        case .sync: balance.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .cloud: "cloud"
        }
    }

    /// Fixed hues rather than the accent colour: a user whose accent is green
    /// would otherwise see two of the three lines claim to be the same thing.
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

    private var barHeight: CGFloat { style == .full ? 8 : 4 }
    private var rowHeight: CGFloat { style == .full ? 16 : 4 }
    private var rowSpacing: CGFloat { style == .full ? 5 : 3 }
}

/// A highlight that crosses the middle line while bytes are actually moving, so
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
