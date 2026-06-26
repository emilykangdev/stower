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

    /// The app-owned `UndoManager` (A4): ONE stable instance the board's dismiss/undo
    /// registrations drive, so the undo stack survives a board reload (unlike
    /// `@Environment(\.undoManager)`, which rebinds when the list rebuilds). The board
    /// view-model flips `groupsByEvent` off so each dismiss is exactly one undo step
    /// (I6). The draining-bar Undo button calls `undo()` on this instance.
    ///
    /// NOTE (A4/B1 spike — DEFERRED): this is deliberately NOT bound to the global
    /// `.undoRedo` menu command. A `CommandGroup(replacing: .undoRedo)` override stole
    /// ⌘Z from the focused draft-composer text editor (typing a draft + ⌘Z would
    /// un-dismiss a board row instead of undoing text). Binding ⌘Z to the board undo
    /// WITHOUT hijacking text-field undo needs a focus-gated command (`@FocusedValue`,
    /// enabled only when no text field is first responder) and an app-runtime smoke
    /// test — out of scope for the headless gate. Until then the draining-bar Undo
    /// button is the undo affordance; ⌘Z keeps its native per-text-field behavior.
    private let undoManager = UndoManager()

    var body: some Scene {
        WindowGroup {
            StowerRootContainer(flusher: appDelegate.flusher, undoManager: undoManager)
        }
    }
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
        // Drain pending draft writes, then let the app quit. `.terminateLater` keeps
        // the app alive until `reply(toApplicationShouldTerminate:)`.
        Task { @MainActor in
            await flusher.flushPendingWork()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
