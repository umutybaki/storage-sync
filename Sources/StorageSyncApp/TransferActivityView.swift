import AppKit
import StorageSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct TransferActivityView: View {
    let job: SyncJob
    @ObservedObject var model: AppModel
    @State private var selection: Set<TransferID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                Picker("Transfer filter", selection: $model.transferActivityFilter) {
                    ForEach(TransferActivityFilter.allCases, id: \.self) { filter in
                        Text(filter.title(count: model.transferActivityCounts[filter]))
                            .tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 410, idealWidth: 500, maxWidth: 620)
            }

            activityContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }

            if model.transferActivityNextCursor != nil {
                HStack {
                    Spacer()
                    Button(model.isLoadingTransferActivity ? "Loading…" : "Load More") {
                        model.loadMoreTransferActivity()
                    }
                    .disabled(model.isLoadingTransferActivity)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        if model.transferActivityItems.isEmpty {
            emptyState
        } else {
            Table(model.transferActivityItems, selection: $selection) {
                TableColumn("Name") { item in
                    TransferNameCell(item: item)
                }
                .width(min: 220, ideal: 360)

                TableColumn("Status") { item in
                    TransferStatusCell(item: item)
                }
                .width(min: 130, ideal: 160)

                TableColumn("Progress") { item in
                    TransferProgressCell(item: item)
                }
                .width(min: 145, ideal: 185)

                TableColumn("Size") { item in
                    Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 75, ideal: 95)

                TableColumn("Updated") { item in
                    Text(item.updatedAt.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 82)
            }
            .contextMenu(forSelectionType: TransferID.self) { identifiers in
                if let item = selectedItem(in: identifiers) {
                    Button("Show in Finder") {
                        model.revealInFinder(item, for: job)
                    }
                    .disabled(!model.canRevealInFinder(item, for: job))
                    Divider()
                    Button("Copy Relative Path") {
                        model.copyRelativePath(item.relativePath)
                    }
                }
            } primaryAction: { identifiers in
                guard let item = selectedItem(in: identifiers),
                      model.canRevealInFinder(item, for: job) else { return }
                model.revealInFinder(item, for: job)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            if model.isLoadingTransferActivity {
                ProgressView()
                Text("Loading Transfers…")
            } else if let error = model.transferActivityError {
                Label("Transfers Unavailable", systemImage: "exclamationmark.triangle")
                Text(error)
            } else {
                Label(emptyTitle, systemImage: emptySymbol)
            }
        } description: {
            if model.transferActivityError == nil, !model.isLoadingTransferActivity {
                Text(emptyDescription)
            }
        }
    }

    private var emptyTitle: String {
        switch model.transferActivityFilter {
        case .all: "No Transfers in This Check"
        case .active: "Nothing Transferring Now"
        case .waiting: "Nothing Waiting"
        case .completed: "Nothing Completed Yet"
        case .issues: "No Issues"
        }
    }

    private var emptySymbol: String {
        model.transferActivityFilter == .issues ? "checkmark.circle" : "tray"
    }

    private var emptyDescription: String {
        switch model.transferActivityFilter {
        case .all:
            "When a check finds new or changed files, they appear here before transfer begins."
        case .active:
            "Files being uploaded, downloaded, or verified appear here."
        case .waiting:
            "Queued files and interrupted transfers appear here."
        case .completed:
            "Completed files remain visible until the next check begins."
        case .issues:
            "This check has no files that need attention or rechecking."
        }
    }

    private func selectedItem(in identifiers: Set<TransferID>) -> TransferActivityItem? {
        guard let id = identifiers.first else { return nil }
        return model.transferActivityItems.first { $0.id == id }
    }
}

private struct TransferNameCell: View {
    let item: TransferActivityItem

    /// Live progress republishes the whole item array many times a second, so
    /// every visible row is rebuilt that often, and resolving a type identifier
    /// and asking the workspace for its icon costs far more than drawing the
    /// row does. The result only depends on the extension, so each distinct one
    /// is looked up once. `View.body` is main-actor isolated, which is what
    /// makes an unsynchronized dictionary safe here.
    @MainActor private static var iconsByExtension: [String: NSImage] = [:]

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(forExtension: fileExtension))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .help(item.relativePath)
    }

    private var path: NSString { item.relativePath as NSString }
    private var fileName: String { path.lastPathComponent }
    private var folder: String {
        let value = path.deletingLastPathComponent
        return value == "." ? "" : value
    }
    private var fileExtension: String {
        let value = path.pathExtension
        return value.isEmpty ? "public.data" : value
    }

    /// Extensions the workspace does not recognize are cached with the generic
    /// icon they fall back to, so a folder full of unknown files does not repeat
    /// the failed lookup on every emit.
    @MainActor
    private static func icon(forExtension fileExtension: String) -> NSImage {
        // Filename extensions are matched case-insensitively, so folding the
        // key keeps one entry per type rather than one per spelling.
        let key = fileExtension.lowercased()
        if let cached = iconsByExtension[key] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        iconsByExtension[key] = icon
        return icon
    }
}

private struct TransferStatusCell: View {
    let item: TransferActivityItem

    var body: some View {
        Label(item.activityStatusTitle, systemImage: item.activityStatusSymbol)
            .foregroundStyle(item.activityStatusColor)
            .lineLimit(1)
            .help(item.lastError ?? item.activityStatusTitle)
    }
}

private struct TransferProgressCell: View {
    let item: TransferActivityItem

    var body: some View {
        switch item.status {
        case .running where visibleBytes == 0 && item.totalBytes > 0:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("In progress")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .running:
            progress
        case .verifying:
            Text("Verifying")
                .foregroundStyle(.secondary)
        case .completed:
            Label("Complete", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        case .waiting where item.completedBytes > 0:
            progress
        default:
            Text("—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("No progress yet")
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(
                value: Double(visibleBytes),
                total: Double(max(1, item.totalBytes))
            )
            Text(
                "\(ByteCountFormatter.string(fromByteCount: visibleBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))\(progressSuffix)"
            )
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityLabel(
            "\(visibleBytes.formatted()) of \(item.totalBytes.formatted()) bytes \(accessibilityProgressVerb)"
        )
    }

    private var visibleBytes: Int64 {
        let live = item.kind == .upload ? item.bytesSent ?? 0 : 0
        return min(item.totalBytes, max(0, max(item.completedBytes, live)))
    }

    private var progressSuffix: String {
        item.status == .running && item.kind == .upload ? " sent" : ""
    }

    private var accessibilityProgressVerb: String {
        if item.status == .running && item.kind == .upload { return "sent" }
        return "completed"
    }
}

private extension TransferActivityFilter {
    func title(count: Int) -> String {
        let name: String
        switch self {
        case .all: name = "All"
        case .active: name = "Active"
        case .waiting: name = "Waiting"
        case .completed: name = "Done"
        case .issues: name = "Issues"
        }
        return "\(name) \(count.formatted())"
    }
}

extension TransferActivityItem {
    var activityStatusTitle: String {
        switch status {
        case .queued:
            return kind == .upload ? "Waiting to upload" : "Waiting to download"
        case .running:
            return kind == .upload ? "Uploading" : "Downloading"
        case .waiting:
            // The engine's own classification, never words found in
            // `lastError`: that text is a localized system message, so reading
            // it names the wrong cause on a non-English system and mistakes an
            // S3 message mentioning a folder for a disconnected drive. Rows
            // written before the blocker was carried through have none, and
            // fall back to the generic wording.
            if let waitingBlocker {
                switch waitingBlocker {
                case .networkUnavailable: return "Waiting for internet"
                case .localVolumeUnavailable: return "Waiting for drive"
                case .insufficientSpace: return "Not enough space"
                case .credentialsUnavailable: return "Sign in again"
                }
            }
            return retryCount > 0 ? "Retrying" : (kind == .upload ? "Waiting to upload" : "Waiting to download")
        case .verifying:
            return "Verifying"
        case .completed:
            return kind == .upload ? "Uploaded" : "Downloaded"
        case .failed:
            return "Needs attention"
        case .superseded:
            return "Rechecking"
        }
    }

    var activityStatusSymbol: String {
        switch status {
        case .queued: "clock"
        case .running: kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .waiting: "pause.circle"
        case .verifying: "checkmark.seal"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .superseded: "arrow.triangle.2.circlepath"
        }
    }

    var activityStatusColor: Color {
        switch status {
        case .running, .verifying: .blue
        case .completed: .green
        case .waiting: .orange
        case .failed: .red
        case .superseded: .orange
        case .queued: .secondary
        }
    }
}
