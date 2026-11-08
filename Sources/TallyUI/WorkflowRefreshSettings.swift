import SwiftUI

struct WorkflowRefreshSettings: View {
    @Bindable var store: TallyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Pause automatic refresh", isOn: $store.automaticRefreshPaused)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.small)
            if store.automaticRefreshPaused {
                Text("Paused until you turn this off, even after relaunch. Refresh now still works; an update already in progress will finish.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Refresh every").font(.callout)
                Spacer()
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                .disabled(store.automaticRefreshPaused)
            }
        }
    }
}
