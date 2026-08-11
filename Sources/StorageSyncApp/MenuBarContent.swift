import AppKit
import StorageSyncCore
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
            // An empty list means "you have no syncs" only once the agent has
            // actually answered. Saying it while the agent is unreachable would
            // claim the user's syncs are gone, and offer to create one they
            // already have.
            if !model.jobs.isEmpty {
                jobList
            } else if model.isAgentAvailable {
                emptyState
            } else {
                unreachableState
            }

            Divider()
            footer
        }
        // A fixed width keeps the popover from jumping every time a job name
        // or a byte count changes length.
        .frame(width: width)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("StorageSync")
                .font(.headline)
            Spacer(minLength: 0)
            Text(model.overallStatus.summary)
                .font(.subheadline)
                .foregroundStyle(model.overallStatus == .attention ? .red : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    /// Roughly three syncs before the list starts scrolling.
    private static let rowsBeforeScrolling = 3
    private static let maximumListHeight: CGFloat = 380

    /// The syncs used to be wrapped in a `ScrollView` constrained only by
    /// `maxHeight`. A scroll view is infinitely flexible with a minimum of
    /// zero, so whenever the popover proposed a height, the stack satisfied the
    /// fixed header and footer first and left the list whatever remained —
    /// which was nothing. The syncs existed and laid out, but drew as an empty
    /// gap.
    ///
    /// Short lists, which is nearly always, now have no scroll view at all and
    /// take their natural height. A long one gets a scroll view with a
    /// *definite* height, which cannot be squeezed away either.
    @ViewBuilder
    private var jobList: some View {
        if model.jobs.count > Self.rowsBeforeScrolling {
            ScrollView(.vertical) { jobRows }
                .frame(height: Self.maximumListHeight)
                .scrollBounceBehavior(.basedOnSize)
        } else {
            jobRows
        }
    }

    private var jobRows: some View {
        VStack(spacing: 1) {
            ForEach(model.jobs) { job in
                MenuJobRow(
                    job: job,
                    snapshot: model.snapshot(for: job.id),
                    connection: model.connection(for: job),
                    model: model,
                    open: { open(job) }
                )
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        // Belt and braces: the rows keep their natural height no matter what
        // the popover proposes, so they can never be compressed to nothing.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No Syncs Yet")
                .font(.headline)
            Text("Pair a folder with an S3 bucket and StorageSync keeps copying new files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create Sync…") {
                model.beginCreatingSync()
                ManagerWindow.show(using: openWindow)
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
    }

    /// Shown instead of the empty state when the list is empty only because the
    /// agent has not answered yet. Existing syncs are untouched and keep
    /// running; this is the manager's view of them that is missing.
    private var unreachableState: some View {
        VStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(model.needsLoginItemsApproval ? "Waiting for Approval" : "Connecting…")
                .font(.headline)
            Text(
                model.needsLoginItemsApproval
                    ? "Turn StorageSync on in Login Items to see your syncs and let them run."
                    : "Reconnecting to the background agent. Your syncs are safe and keep running."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
    }

    private var footer: some View {
        VStack(spacing: 1) {
            if !model.isAgentAvailable {
                if model.needsLoginItemsApproval {
                    MenuActionRow(
                        title: "Allow StorageSync in Login Items",
                        systemImage: "exclamationmark.triangle.fill",
                        help: "Background syncing stays off until StorageSync is turned on in System Settings."
                    ) {
                        model.openLoginItemsSettings()
                    }
                } else {
                    MenuNoticeRow(
                        text: "Starting background syncing…",
                        systemImage: "clock.arrow.circlepath",
                        tint: .secondary
                    )
                }
            }
            MenuActionRow(title: "Open StorageSync", systemImage: "macwindow") {
                ManagerWindow.show(using: openWindow)
            }
            MenuActionRow(
                title: "Quit StorageSync",
                systemImage: "power",
                help: "Stops syncing and closes the background agent. Progress is saved and resumes when you open StorageSync again."
            ) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    private func open(_ job: SyncJob) {
        model.selectedJobID = job.id
        ManagerWindow.show(using: openWindow)
    }
}

private struct MenuJobRow: View {
    let job: SyncJob
    let snapshot: SyncSnapshot
    let connection: S3Connection?
    @ObservedObject var model: AppModel
    let open: () -> Void

    @State private var isHovering = false

    private var status: SyncStatus { SyncStatus(job: job, snapshot: snapshot) }

    var body: some View {
        // Two real buttons rather than a tap gesture over the whole row, so
        // the pause control stays reachable from the keyboard and VoiceOver.
        HStack(alignment: .top, spacing: 9) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: SyncRoute.symbol(job))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .padding(.top, 1)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.name)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Label {
                            Text(status.title).lineLimit(1)
                        } icon: {
                            Image(systemName: status.symbol).foregroundStyle(status.tint)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.statusLine)

                        if snapshot.hasMeasurableProgress {
                            ProgressView(value: snapshot.fractionCompleted)
                                .controlSize(.small)
                                .padding(.top, 1)
                            Text(snapshot.progressSummary)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else if let inventory = snapshot.inventory, inventory.found > 0 {
                            Text(countSummary(inventory))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(job.name). \(status.title). Open in StorageSync.")

            TransportButton(isPaused: job.isPaused) {
                Task {
                    if job.isPaused { await model.resume(job) } else { await model.pause(job) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
        }
        .onHover { isHovering = $0 }
        .help(SyncRoute.text(job, connection: connection))
    }

    private func countSummary(_ inventory: SyncInventory) -> String {
        if inventory.remaining > 0 {
            return "\(inventory.remaining.formatted()) of \(inventory.found.formatted()) files remaining"
        }
        return "\(inventory.found.formatted()) files"
    }
}

private struct TransportButton: View {
    let isPaused: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isPaused ? "Resume this sync" : "Pause this sync")
        .accessibilityLabel(isPaused ? "Resume" : "Pause")
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .modifier(OptionalHelp(text: help))
    }
}

/// `help("")` still shows an empty tooltip, so the modifier has to be skipped
/// entirely when there is nothing to say.
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

private struct MenuNoticeRow: View {
    let text: String
    let systemImage: String
    var tint: Color = .orange

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pulls the status glyph tight against its sentence so a row reads as one
/// line rather than an icon column plus text.
private struct StatusLineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == StatusLineLabelStyle {
    static var statusLine: StatusLineLabelStyle { StatusLineLabelStyle() }
}
