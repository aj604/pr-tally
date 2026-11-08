import SwiftUI

enum WorkflowRefreshPause: CaseIterable {
    case oneHour, untilTomorrow

    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .untilTomorrow: "Until tomorrow"
        }
    }

    func deadline(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: now.addingTimeInterval(60 * 60)
        case .untilTomorrow: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        }
    }
}

extension TallyStore {
    var workflowRefreshPauseExplanation: String {
        let timing = automaticRefreshResumeAt.map {
            "Resumes automatically \($0.formatted(date: .abbreviated, time: .shortened)), even after relaunch."
        } ?? "Paused until you turn this off, even after relaunch."
        return "\(timing) Refresh now still works; an update already in progress will finish."
    }
}

struct WorkflowRefreshSettings: View {
    @Bindable var store: TallyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Pause automatic refresh", isOn: $store.automaticRefreshPaused)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.small)
            Menu("Pause for…") {
                ForEach(WorkflowRefreshPause.allCases, id: \.self) { pause in
                    Button(pause.title) { store.pauseAutomaticRefresh(until: pause.deadline(from: Date())) }
                }
            }
            .controlSize(.small)
            if store.automaticRefreshPaused {
                Text(store.workflowRefreshPauseExplanation)
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
