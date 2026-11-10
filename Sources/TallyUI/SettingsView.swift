import ServiceManagement
import SwiftUI
import TallyCore

struct SettingsView: View {
    @Bindable var store: TallyStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?
    @State private var tokenDraft = ""
    @State private var hasSavedToken: Bool
    @State private var savedTokenIsFineGrained: Bool
    @State private var tokenFailed = false
    /// Counts saved and cleared tokens, so the saved one's scopes are checked again.
    @State private var tokenChanges = 0
    @State private var notificationsDenied = false

    /// `savedToken` is only looked at for what kind of token it is, and defaults to the keychain's.
    init(store: TallyStore, savedToken: String? = KeychainToken.standard.read()) {
        self.store = store
        _hasSavedToken = State(initialValue: savedToken != nil)
        _savedTokenIsFineGrained = State(initialValue: savedToken.map(Self.isFineGrained) ?? false)
    }

    /// GitHub's default new token is fine-grained, which belongs to one user or org. Whether search then leaves
    /// out private repos under other owners is undocumented, so the warning says "can".
    static func isFineGrained(_ token: String) -> Bool {
        token.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("github_pat_")
    }

    static let fineGrainedWarning =
        "A fine-grained token covers one account or org. If your PRs are in private repos under more than one, "
        + "counts can come up short with no error. A classic token with the `repo` scope, authorized for any SSO orgs, covers them."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Count toward goal") {
                Picker("Count toward goal", selection: $store.metric) {
                    ForEach(PRMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            row("Monthly goal") {
                TextField("Goal", value: $store.goal, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            Text("Opened and merged PRs each keep their own monthly goal.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WorkflowGoalPreview(plan: store.workflowGoalPlan()) { store.goal = $0 }
            WorkflowMenuBarSettings(store: store)
            WorkflowRefreshSettings(store: store)
            Toggle("Notify when I hit my goal", isOn: $store.notifiesOnGoal)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.small)
            if store.notifiesOnGoal, notificationsDenied {
                Text("Notifications for PR Tally are off in System Settings > Notifications.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let launchMessage {
                Text(launchMessage).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            token
        }
        .task { notificationsDenied = await MilestoneNotifier.shared.isDenied() }
    }

    private var token: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub login").font(.callout)
            let status = store.workflowLoginStatus(usesSavedToken: hasSavedToken)
            Text(LocalizedStringKey(status.text))
                .font(.caption)
                .foregroundStyle(status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Personal access token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: saveToken)
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedToken {
                    Button("Clear", action: clearToken)
                }
            }
            .controlSize(.small)
            if tokenFailed {
                Text("Couldn't save the token to your keychain.").font(.caption).foregroundStyle(.orange)
            }
            if savedTokenIsFineGrained || Self.isFineGrained(tokenDraft) {
                Text(LocalizedStringKey(Self.fineGrainedWarning))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // On every opening too, since a classic token's scopes can be changed on GitHub without changing the token.
        .task(id: tokenChanges) {
            guard hasSavedToken, let token = KeychainToken.standard.read() else { return }
            await store.checkSavedToken(token)
        }
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            control()
        }
    }

    private func saveToken() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenFailed = !KeychainToken.standard.save(token)
        guard !tokenFailed else { return }
        savedTokenIsFineGrained = Self.isFineGrained(token)
        tokenDraft = ""
        hasSavedToken = true
        tokenChanges += 1
        Task { await store.loginChanged() }
    }

    private func clearToken() {
        KeychainToken.standard.delete()
        hasSavedToken = false
        savedTokenIsFineGrained = false
        tokenChanges += 1
        Task { await store.loginChanged() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchMessage = service.status == .requiresApproval
                ? "Allow PR Tally in System Settings > General > Login Items."
                : nil
        } catch {
            launchMessage = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }
}
