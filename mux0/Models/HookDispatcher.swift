import Foundation

/// Stateless filter + fanout from `HookMessage` to `TerminalStatusStore`.
///
/// Extracted out of `ContentView.onMessage` so the per-agent gate can be
/// unit-tested without plumbing an in-process Unix socket. The listener still
/// owns the socket and the main-hop; it calls `dispatch` with each decoded
/// message.
///
/// Filter policy: a message is forwarded iff the user has enabled its agent
/// in Settings → Agents (per-agent key `mux0-agent-status-<rawValue>` == "true").
/// Missing or any non-"true" value = disabled. Shell is not representable —
/// the enum no longer has `.shell`, and the socket listener's JSONDecoder
/// drops stray shell-agent payloads before they reach this function.
enum HookDispatcher {
    /// Lightweight event carrier consumed by the notifier. `NotificationManager`
    /// currently only needs the event *kind* (it just plays a sound), but the
    /// associated data is preserved so future code paths — e.g. routing the
    /// click destination back to a specific tab — don't have to reshape the
    /// dispatcher.
    enum NotifyEvent {
        case needsInput(terminalId: UUID, agent: HookMessage.Agent)
        case finished(terminalId: UUID, agent: HookMessage.Agent,
                      exitCode: Int32, duration: TimeInterval, summary: String?)
    }

    static func dispatch(_ msg: HookMessage,
                         settings: SettingsConfigStore,
                         store: TerminalStatusStore,
                         workspaceStore: WorkspaceStore? = nil,
                         notify: ((NotifyEvent) -> Void)? = nil) {
        // Resume is gated independently from the status (notifications)
        // toggle: a user who only wants auto-resume but doesn't want the
        // running/idle icons should still get their session id persisted.
        if let cmd = msg.resumeCommand, let ws = workspaceStore,
           settings.get(msg.agent.resumeSettingsKey) == "true" {
            ws.recordResumeCommand(terminalId: msg.terminalId, command: cmd)
        }
        guard settings.get(msg.agent.settingsKey) == "true" else { return }
        switch msg.event {
        case .running:
            store.setRunning(terminalId: msg.terminalId,
                             at: msg.timestamp,
                             detail: msg.toolDetail)
        case .idle:
            // codex-wrapper always injects `notify = [..., "idle", "codex"]`
            // via codex's `-c` CLI override, which fires an `idle` on every
            // turn completion. When the user also has `features.codex_hooks = true`,
            // the Stop hook fires `finished` (with exitCode) at the same point,
            // and the two socket writes race: the notify-driven `idle` often
            // arrives after the Stop-driven `finished` and would overwrite the
            // success/failed state with a neutral idle. Claude's SessionEnd
            // shares the same shape (Stop emits `finished`, SessionEnd emits
            // `idle`). Keep the informative terminal state; the next
            // UserPromptSubmit will move things back to `.running`.
            switch store.status(for: msg.terminalId) {
            case .success, .failed: return
            default: break
            }
            store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
        case .needsInput:
            // Claude Code's Notification hook fires for two reasons: a real
            // permission request during a live turn, or a 60-second idle
            // heartbeat after the turn has ended. Only promote to needsInput
            // while the terminal is still running — otherwise the heartbeat
            // would overwrite a terminal success/failed one minute later.
            if case .running = store.status(for: msg.terminalId) {
                let before = store.status(for: msg.terminalId)
                store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
                // Only notify when the state actually flipped (a stale event
                // suppressed by the store wouldn't change the public state and
                // shouldn't ring the user).
                if case .needsInput = store.status(for: msg.terminalId),
                   case .running = before {
                    notify?(.needsInput(terminalId: msg.terminalId, agent: msg.agent))
                }
            }
        case .finished:
            // hook-emit.sh degrades malformed `finished` to `idle` before it
            // reaches us; this guard is defense in depth.
            guard let ec = msg.exitCode else { return }
            let before = store.status(for: msg.terminalId)
            store.setFinished(terminalId: msg.terminalId, exitCode: ec,
                              at: msg.timestamp, agent: msg.agent,
                              summary: msg.summary)
            // Notify only when the store actually accepted the event (stale
            // timestamps are silently dropped by setFinished's isStale guard).
            // Use the post-state's duration so the notification matches the
            // tooltip the user will see in the sidebar.
            let after = store.status(for: msg.terminalId)
            switch (before, after) {
            case (.success, .success), (.failed, .failed):
                return
            default: break
            }
            let duration: TimeInterval = {
                switch after {
                case .success(_, let d, _, _, _, _): return d
                case .failed(_, let d, _, _, _, _):  return d
                default: return 0
                }
            }()
            if case .success = after {
                notify?(.finished(terminalId: msg.terminalId, agent: msg.agent,
                                  exitCode: ec, duration: duration, summary: msg.summary))
            } else if case .failed = after {
                notify?(.finished(terminalId: msg.terminalId, agent: msg.agent,
                                  exitCode: ec, duration: duration, summary: msg.summary))
            }
        }
    }
}

/// Master UI gate: is the status indicator column visible anywhere?
///
/// True iff the user has enabled at least one agent in Settings → Agents.
/// All other downstream plumbing (`SidebarListBridge.showStatusIndicators`,
/// `TabBridge.showStatusIndicators`, icon rendering) continues to consume a
/// single Bool — this helper is its authoritative source.
enum StatusIndicatorGate {
    static func anyAgentEnabled(_ settings: SettingsConfigStore) -> Bool {
        HookMessage.Agent.allCases.contains { agent in
            settings.get(agent.settingsKey) == "true"
        }
    }
}
