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

    var body: some Scene {
        WindowGroup {
            StowerRootContainer(flusher: appDelegate.flusher)
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

    init(flusher: StowerTerminationFlusher) {
        _root = State(initialValue: Result { try StowerRootView(flusher: flusher) })
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
                        + "Free some disk space and reopen Stower."
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
