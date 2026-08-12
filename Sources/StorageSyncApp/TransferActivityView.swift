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
                .fixedSize()
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
                .width(min: 115, ideal: 145)

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

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: contentType))
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
    private var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
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
        case .running where item.completedBytes == 0 && item.totalBytes > 0:
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
                value: Double(min(item.totalBytes, max(0, item.completedBytes))),
                total: Double(max(1, item.totalBytes))
            )
            Text(
                "\(ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))"
            )
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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
            if let error = lastError?.lowercased() {
                if error.contains("network") || error.contains("internet") || error.contains("timed out") {
                    return "Waiting for internet"
                }
                if error.contains("volume") || error.contains("drive") || error.contains("folder") {
                    return "Waiting for drive"
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
