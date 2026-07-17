import CMUXAgentLaunch
import CmuxSettings
import Foundation

struct FeedNotificationPolicyContext: Sendable {
    let envelope: TerminalNotificationPolicyEnvelope
    let hooks: [CmuxResolvedNotificationHook]
    let globalConfigPath: String?
}

extension FeedNotificationPolicyContext {
    static func make(
        event: WorkstreamEvent,
        title: String,
        body: String
    ) async -> FeedNotificationPolicyContext {
        let snapshot = await MainActor.run {
            snapshot(event: event, title: title, body: body)
        }
        guard let globalConfigPath = snapshot.globalConfigPath else {
            return FeedNotificationPolicyContext(
                envelope: snapshot.envelope,
                hooks: [],
                globalConfigPath: nil
            )
        }
        let hooks = await Task.detached(priority: .utility) {
            CmuxConfigStore(
                globalConfigPath: globalConfigPath,
                startFileWatchers: false
            ).notificationHooks(startingFrom: snapshot.hookSearchDirectory)
        }.value
        return FeedNotificationPolicyContext(
            envelope: snapshot.envelope,
            hooks: hooks,
            globalConfigPath: globalConfigPath
        )
    }

    @MainActor
    private static func snapshot(
        event: WorkstreamEvent,
        title: String,
        body: String
    ) -> (
        envelope: TerminalNotificationPolicyEnvelope,
        globalConfigPath: String?,
        hookSearchDirectory: String?
    ) {
        let appDelegate = AppDelegate.shared
        let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:))
        let context = workspaceID.flatMap { appDelegate?.contextContainingTabId($0) }
        let workspace = workspaceID.flatMap { id in
            context?.tabManager.tabs.first(where: { $0.id == id })
        }
        let cwd = normalizedCWD(event.cwd)
            ?? workspace?.surfaceTabBarDirectory
            ?? workspace?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = true
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.sound = false
        effects.command = false
        effects.paneFlash = false

        let workspaceIdentity = workspaceID?.uuidString ?? ""
        let hookSearchDirectory = workspace.map { workspace in
            workspace.isRemoteWorkspace
                ? nil
                : (normalizedCWD(event.cwd) ?? workspace.surfaceTabBarDirectory)
        } ?? nil
        return (
            TerminalNotificationPolicyEnvelope(
                notification: TerminalNotificationPolicyPayload(
                    workspaceId: workspaceIdentity,
                    surfaceId: nil,
                    title: title,
                    subtitle: "",
                    body: body
                ),
                context: TerminalNotificationPolicyContext(
                    cwd: cwd,
                    configPath: nil,
                    hookId: nil,
                    appFocused: AppFocusState.isAppFocused(),
                    focusedPanel: false
                ),
                effects: effects
            ),
            workspace == nil ? nil : context?.cmuxConfigStore?.globalConfigPath,
            hookSearchDirectory
        )
    }

    private static func normalizedCWD(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
