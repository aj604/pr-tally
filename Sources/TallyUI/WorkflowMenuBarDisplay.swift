import SwiftUI

/// Both displays follow the goal's metric; the ring always shows monthly pace.
public enum WorkflowMenuBarDisplay: String, CaseIterable, Identifiable, Sendable {
    case today
    case monthProgress

    public var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today's count"
        case .monthProgress: "Month progress"
        }
    }

    var explanation: String {
        switch self {
        case .today: "Today's count turns green above the daily quota. The ring shows monthly pace."
        case .monthProgress: "Month count/goal turns green when the goal is reached. The ring shows monthly pace."
        }
    }
}

struct WorkflowMenuBarSettings: View {
    @Bindable var store: TallyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Menu bar number").font(.callout)
                Spacer()
                Picker("Menu bar number", selection: $store.menuBarDisplay) {
                    ForEach(WorkflowMenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            Text(store.menuBarDisplay.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
