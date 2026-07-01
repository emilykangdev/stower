//
//  StowerMacApp.swift
//  StowerMac
//
//  Created by Emily Kang on 6/14/26.
//

import AppKit
import StowerMacUI
import SwiftUI

@main
struct StowerMacApp: App {
    @NSApplicationDelegateAdaptor(StowerAppDelegate.self) private var appDelegate
    @StateObject private var updaterController = StowerUpdaterController()

    /// The app-owned `UndoManager` (A4): ONE stable instance the board's dismiss/undo
    /// registrations drive, so the undo stack survives a board reload (unlike
    /// `@Environment(\.undoManager)`, which rebinds when the list rebuilds). The board
    /// view-model flips `groupsByEvent` off so each dismiss is exactly one undo step
    /// (I6). Both ⌘Z and the draining-bar Undo button call `undo()` on this instance.
    private let undoManager = UndoManager()

    init() {
        // Initialize all diagnostics backends (crash reporting + analytics)
        // behind the shared consent gate. Sentry crash handler starts first
        // (earliest crash coverage, JC3); TelemetryDeck follows. When consent is
        // off, initialize() is a complete no-op — no SDK init, no crash handler,
        // no automatic Session.started (A3/JC3).
        StowerDiagnostics.initialize()
        // app_launched is gated by the analytics facade; no-op if disabled.
        StowerAnalytics.reportAppLaunched()
    }

    var body: some Scene {
        WindowGroup {
            StowerRootContainer(flusher: appDelegate.flusher, undoManager: undoManager)
        }
        .commands {
            // ⌘Z / ⌘⇧Z (A4/B1 spike — resolved WITHOUT an AppKit responder bridge in the
            // board; the only AppKit here is forwarding the action the standard Edit-menu
            // item already uses). We replace `.undoRedo` so ⌘Z can reach the board's undo,
            // but FIRST forward `undo:`/`redo:` down the responder chain — exactly what the
            // default Undo item does (`action: undo:, target: nil`). When a draft-composer
            // text field is first responder it handles its own text undo and we stop;
            // ONLY when nothing in the chain handles it does the board dismiss-undo run.
            // So text-field undo is preserved and ⌘Z reverses a dismiss when not editing.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            #if DEBUG
            // DEBUG-only: force a crash to verify the Sentry capture → next-launch
            // upload → EU dashboard pipeline. Never compiled into a release build.
            CommandMenu("Debug") {
                Button("Force Crash (Sentry test)") {
                    StowerDiagnostics.debugForceCrash()
                }
            }
            #endif
        }
        // SwiftUI allows exactly one Settings scene. The Privacy pane (library
        // module) and the Updates pane (app target) are composed into that single
        // scene by passing the updater pane in as an additional tab.
        Settings {
            StowerSettingsView {
                StowerUpdaterSettingsView(controller: updaterController)
                    .tabItem {
                        Label("Updates", systemImage: "arrow.down.circle")
                    }
            }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates()
                }
            }
        }
    }

    /// Forwards to the focused responder's text undo; falls back to the board undo when
    /// nothing in the responder chain handled it (no text field is editing).
    private func performUndo() {
        if !NSApp.sendAction(Self.undoActionSelector, to: nil, from: nil) {
            undoManager.undo()
        }
    }

    /// The redo mirror of `performUndo`.
    private func performRedo() {
        if !NSApp.sendAction(Self.redoActionSelector, to: nil, from: nil) {
            undoManager.redo()
        }
    }

    /// The standard first-responder Edit-menu undo/redo actions (`undo:` / `redo:`).
    private static let undoActionSelector = Selector(("undo:"))
    private static let redoActionSelector = Selector(("redo:"))
}

/// Builds the root once, surfacing a startup failure if an essential store (the
/// precious drafts database) can't be opened on a true disk-level fault.
///
/// `StowerRootView`'s production init throws only in that essential-store case; the
/// container builds it a single time (`@State`) so the store isn't reopened on every
/// body evaluation.
private struct StowerRootContainer: View {
    @State private var root: Result<StowerRootView, Error>

    init(flusher: StowerTerminationFlusher, undoManager: UndoManager) {
        _root = State(
            initialValue: Result {
                try StowerRootView(flusher: flusher, undoManager: undoManager)
            }
        )
    }

    var body: some View {
        switch root {
        case .success(let view):
            view
        case .failure:
            ContentUnavailableView(
                "Stower couldn't open your data",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(
                    "There wasn't enough room or permission to open Stower's storage. "
                        + "Free disk space, verify Stower can access its storage "
                        + "location, and reopen Stower."
                )
            )
        }
    }
}

/// The app delegate: drains in-flight draft writes on quit so a graceful Cmd-Q
/// loses nothing (JC2).
final class StowerAppDelegate: NSObject, NSApplicationDelegate {
    /// Wired to the board view-model's `flushAll()` by `StowerRootView`.
    let flusher = StowerTerminationFlusher()

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Emit session_ended synchronously before draining drafts. The SDK buffers
        // this signal to disk and flushes on next launch (A2/Gotcha 7) — do NOT
        // await here, and do NOT call requestImmediateSync(), which would delay quit.
        StowerAnalytics.reportSessionEnded()
        // Drain pending draft writes, then let the app quit. `.terminateLater` keeps
        // the app alive until `reply(toApplicationShouldTerminate:)`.
        Task { @MainActor in
            await flusher.flushPendingWork()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
