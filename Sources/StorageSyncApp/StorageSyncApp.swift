import AppKit
import SwiftUI

@main
struct StorageSyncApplication: App {
    @NSApplicationDelegateAdaptor(StorageSyncAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("StorageSync")
        }
        .menuBarExtraStyle(.window)

        Window("StorageSync", id: ManagerWindow.id) {
            StorageSyncWindow(model: model)
                // Keep the sidebar and all five sortable columns readable.
                .frame(minWidth: 960, minHeight: 540)
                .onAppear { ManagerWindow.didOpen() }
                .onDisappear { ManagerWindow.didClose() }
        }
        .defaultSize(width: 1080, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Sync…") { model.beginCreatingSync() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Sync Now") {
                    guard let job = model.selectedJob else { return }
                    Task { await model.syncNow(job) }
                }
                .keyboardShortcut("r")
                .disabled(model.selectedJob.map { !model.canSyncNow($0) } ?? true)
            }
            // There is no help book to open, so an entry that does nothing is
            // worse than no entry.
            CommandGroup(replacing: .help) {}
        }
    }
}

final class StorageSyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    // Closing the manager window must never quit an app whose whole point is
    // to keep running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting StorageSync stops syncing outright: the menu bar icon going away
    /// means nothing is left running. Termination is deferred just long enough
    /// to tell the agent to stop, because killing this process alone would
    /// leave the engine transferring with no way to see or stop it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = ActiveAppModel.current else { return .terminateNow }
        Task {
            await model.shutdownAgentForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { ManagerWindow.reconcile() } }
    }
}

/// A menu bar app that also owns a real window has to switch activation policy
/// while that window is up. As a pure accessory it gets no menu bar, which
/// silently breaks ⌘C/⌘V in the credential fields, ⌘W, and ⌘Q. The Dock icon
/// appears only for as long as the window is open.
@MainActor
enum ManagerWindow {
    static let id = "main"

    static func didOpen() {
        apply(regular: true)
    }

    /// Demotion is decided by the real window list rather than by trusting the
    /// callback: SwiftUI can tear a scene down transiently, and a spurious
    /// demotion would silently take the menu bar away from an open window.
    static func didClose() {
        DispatchQueue.main.async { reconcile() }
    }

    static func reconcile() {
        apply(regular: hasVisibleWindow)
    }

    static func show(using openWindow: OpenWindowAction) {
        openWindow(id: id)
        apply(regular: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The menu bar popover is a panel that never becomes main, so this counts
    /// only the manager window.
    private static var hasVisibleWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && window.styleMask.contains(.titled)
        }
    }

    private static func apply(regular: Bool) {
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
