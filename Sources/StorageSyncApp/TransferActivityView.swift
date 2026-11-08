import AppKit
import StorageSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct TransferActivityView: View {
    let job: SyncJob
    @ObservedObject var model: AppModel
    @State private var selection: Set<TransferID> = []
    @State private var sortOrder: [KeyPathComparator<TransferActivityItem>]
    @State private var pageNumber = "1"

    init(job: SyncJob, model: AppModel) {
        self.job = job
        self.model = model
        _sortOrder = State(initialValue: [Self.comparator(for: model.transferActivitySort)])
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(model.transferActivityItems, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.fileName) { item in
                    TransferNameCell(item: item)
                }
                .width(min: 160, ideal: 340)

                TableColumn("Status", value: \.status.rawValue) { item in
                    Label(item.activityStatusTitle, systemImage: item.activityStatusSymbol)
                        .foregroundStyle(item.activityStatusColor)
                        .lineLimit(1)
                        .help(item.lastError ?? item.activityStatusTitle)
                }
                .width(min: 130, ideal: 150)

                TableColumn("Progress", value: \.progressFraction) { item in
                    TransferProgressCell(item: item)
                }
                .width(min: 85, ideal: 100)

                TableColumn("Size", value: \.totalBytes) { item in
                    Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 65, ideal: 85)

                TableColumn("Updated", value: \.updatedAt) { item in
                    Text(item.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(item.updatedAt.formatted(date: .complete, time: .standard))
                }
                .width(min: 125, ideal: 140)
            }
            .controlSize(.small)
            .font(.system(size: 12))
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .tableColumnHeaders(.visible)
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(-1)
            .contextMenu(forSelectionType: TransferID.self) { identifiers in
                if let item = selectedItem(in: identifiers) {
                    Button("Show in Finder") { model.revealInFinder(item, for: job) }
                        .disabled(!model.canRevealInFinder(item, for: job))
                    Divider()
                    Button("Copy Relative Path") { model.copyRelativePath(item.relativePath) }
                }
            } primaryAction: { identifiers in
                guard let item = selectedItem(in: identifiers),
                      model.canRevealInFinder(item, for: job) else { return }
                model.revealInFinder(item, for: job)
            }
            // A new page/sort starts at its first row. Progress and revision
            // updates preserve the current scroll position and selection.
            .id("\(model.transferActivityPageIndex)-\(model.transferActivitySort.column.rawValue)-\(model.transferActivitySort.ascending)")
            .overlay(alignment: .top) {
                if model.transferActivityItems.isEmpty {
                    emptyState.padding(.top, 48)
                }
            }

            if model.transferActivityCounts.all > AppModel.transferActivityPageSize {
                pagination
            } else if model.transferActivityError != nil && !model.transferActivityItems.isEmpty {
                errorNotice
            }
        }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            let column: TransferActivitySortColumn
            switch first.keyPath {
            case \TransferActivityItem.fileName: column = .name
            case \TransferActivityItem.status.rawValue: column = .status
            case \TransferActivityItem.progressFraction: column = .progress
            case \TransferActivityItem.totalBytes: column = .size
            default: column = .updated
            }
            selection = []
            model.transferActivitySort = TransferActivitySort(column: column, ascending: first.order == .forward)
        }
        .onChange(of: model.transferActivityPageIndex) { _, index in
            selection = []
            pageNumber = String(index + 1)
        }
    }

    private var pagination: some View {
        HStack(spacing: 10) {
            if let error = model.transferActivityError {
                Label("Couldn’t load this page", systemImage: "exclamationmark.triangle")
                    .help(error)
                Button("Retry") { model.showTransferActivityPage(model.transferActivityPageIndex) }
            } else {
                Text(model.transferActivityItems.isEmpty && model.isLoadingTransferActivity
                     ? "Loading page…"
                     : "\(firstVisible.formatted())–\(lastVisible.formatted()) of \(model.transferActivityCounts.all.formatted()) items")
            }
            Spacer(minLength: 8)
            if model.isLoadingTransferActivity {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Loading page")
            }
            Button {
                model.showTransferActivityPage(model.transferActivityPageIndex - 1)
            } label: { Image(systemName: "chevron.left") }
                .disabled(model.transferActivityPageIndex == 0 || model.isLoadingTransferActivity)
                .help("Previous page")
                .accessibilityLabel("Previous page")
            Text("Page")
            TextField("Page", text: $pageNumber)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .disabled(model.isLoadingTransferActivity)
                .onSubmit {
                    let requested = Int(pageNumber) ?? (model.transferActivityPageIndex + 1)
                    model.showTransferActivityPage(requested > 0 ? requested - 1 : 0)
                    pageNumber = String(model.transferActivityPageIndex + 1)
                }
            Text("of \(model.transferActivityPageCount.formatted())")
            Button {
                model.showTransferActivityPage(model.transferActivityPageIndex + 1)
            } label: { Image(systemName: "chevron.right") }
                .disabled(model.transferActivityPageIndex + 1 >= model.transferActivityPageCount || model.isLoadingTransferActivity)
                .help("Next page")
                .accessibilityLabel("Next page")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var firstVisible: Int {
        model.transferActivityItems.isEmpty ? 0 : model.transferActivityPageIndex * AppModel.transferActivityPageSize + 1
    }

    private var lastVisible: Int {
        model.transferActivityPageIndex * AppModel.transferActivityPageSize + model.transferActivityItems.count
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoadingTransferActivity {
            ProgressView("Loading items…").controlSize(.small)
        } else if model.transferActivityError != nil {
            errorNotice
        }
    }

    private var errorNotice: some View {
        HStack(spacing: 8) {
            Label("Couldn’t load items", systemImage: "exclamationmark.triangle")
                .help(model.transferActivityError ?? "")
            Button("Retry") { model.showTransferActivityPage(model.transferActivityPageIndex) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(8)
    }

    private func selectedItem(in identifiers: Set<TransferID>) -> TransferActivityItem? {
        guard let id = identifiers.first else { return nil }
        return model.transferActivityItems.first { $0.id == id }
    }

    private static func comparator(for sort: TransferActivitySort) -> KeyPathComparator<TransferActivityItem> {
        let order: SortOrder = sort.ascending ? .forward : .reverse
        switch sort.column {
        case .name: return KeyPathComparator(\.fileName, order: order)
        case .status: return KeyPathComparator(\.status.rawValue, order: order)
        case .progress: return KeyPathComparator(\.progressFraction, order: order)
        case .size: return KeyPathComparator(\.totalBytes, order: order)
        case .updated: return KeyPathComparator(\.updatedAt, order: order)
        }
    }
}

private struct TransferNameCell: View {
    let item: TransferActivityItem
    @MainActor private static var iconsByExtension: [String: NSImage] = [:]

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon(forExtension: (item.relativePath as NSString).pathExtension))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(item.relativePath)
        .accessibilityLabel(item.relativePath)
    }

    @MainActor private static func icon(forExtension fileExtension: String) -> NSImage {
        let key = fileExtension.lowercased()
        if let cached = iconsByExtension[key] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        // Bound the cache even when every file has a different extension.
        if iconsByExtension.count < 256 { iconsByExtension[key] = icon }
        return icon
    }
}

private struct TransferProgressCell: View {
    let item: TransferActivityItem

    var body: some View {
        if item.status == .running || (item.status == .waiting && item.completedBytes > 0) {
            HStack(spacing: 6) {
                ProgressView(value: Double(visibleBytes), total: Double(max(1, item.totalBytes)))
                    .frame(width: 40)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help("\(ByteCountFormatter.string(fromByteCount: visibleBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))\(item.kind == .upload ? " sent" : " completed")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(visibleBytes.formatted()) of \(item.totalBytes.formatted()) bytes \(item.kind == .upload ? "sent" : "completed")")
        } else {
            Text(item.status == .completed ? "100%" : item.status == .verifying ? "Verifying" : "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var visibleBytes: Int64 {
        min(item.totalBytes, max(0, max(item.completedBytes, item.kind == .upload ? item.bytesSent ?? 0 : 0)))
    }
    private var fraction: Double { Double(visibleBytes) / Double(max(1, item.totalBytes)) }
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
                case .providerIncompatible: return "Unsupported S3 provider"
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
