import ServiceManagement
import SwiftUI
import TallyCore

struct SettingsView: View {
    @Bindable var store: TallyStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?
    @State private var tokenDraft = ""
    @State private var hasSavedToken = KeychainToken.standard.read() != nil
    @State private var tokenFailed = false
    @State private var notificationsDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Monthly goal") {
                TextField("Goal", value: $store.goal, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            row("Count toward goal") {
                Picker("Count toward goal", selection: $store.metric) {
                    ForEach(PRMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            row("Refresh every") {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
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
            Text(
                hasSavedToken
                    ? "Using the token saved in your keychain."
                    : "Using your gh login. To use a different account, save a token with the `repo` scope."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
        tokenDraft = ""
        hasSavedToken = true
        Task { await store.refresh() }
    }

    private func clearToken() {
        KeychainToken.standard.delete()
        hasSavedToken = false
        Task { await store.refresh() }
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
