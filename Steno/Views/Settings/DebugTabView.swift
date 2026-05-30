import SwiftUI
import AppKit

struct DebugTabView: View {
    @State private var events: [LogEvent] = []
    @State private var selectedSubsystems: Set<LogSubsystem> = Set(LogSubsystem.allCases)
    @State private var minLevel: LogLevel = .info
    @State private var subsystemCounts: [LogSubsystem: Int] = [:]
    @State private var subsystemLastTimes: [LogSubsystem: Date] = [:]
    @State private var refreshTimer: Timer?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            subsystemSummary
                .padding()
                .background(Color(.windowBackgroundColor))

            Divider()

            filterBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            if events.isEmpty {
                emptyState
            } else {
                eventList
            }

            Divider()

            actionBar
                .padding()
        }
        .onAppear {
            refresh()
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
    }

    private var subsystemSummary: some View {
        HStack(spacing: 16) {
            ForEach(LogSubsystem.allCases) { subsystem in
                VStack(alignment: .leading, spacing: 2) {
                    Text(subsystem.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(subsystemCounts[subsystem, default: 0])")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.primary)
                    if let last = subsystemLastTimes[subsystem] {
                        Text(timeFormatter.string(from: last))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("—")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
    }

    private var filterBar: some View {
        HStack {
            ForEach(LogSubsystem.allCases) { subsystem in
                Toggle(isOn: Binding(
                    get: { selectedSubsystems.contains(subsystem) },
                    set: { isOn in
                        if isOn { selectedSubsystems.insert(subsystem) }
                        else { selectedSubsystems.remove(subsystem) }
                        refresh()
                    }
                )) {
                    Text(subsystem.displayName)
                        .font(.caption)
                }
                .toggleStyle(.button)
            }

            Spacer()

            Picker("Level", selection: $minLevel) {
                ForEach(LogLevel.allCases) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .onChange(of: minLevel) { _, _ in refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No events match the current filter.")
                .foregroundStyle(.secondary)
            Text("Try lowering the level threshold or selecting more subsystems.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(events.reversed()) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(timeFormatter.string(from: event.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 90, alignment: .leading)

                    Text(event.subsystem.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Text(event.level.rawValue.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color(for: event.level))
                        .frame(width: 60, alignment: .leading)

                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .id(event.id)
            }
            .listStyle(.plain)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Copy to Clipboard") {
                copyToClipboard()
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Clear") {
                LogStore.shared.clear()
                refresh()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func refresh() {
        events = LogStore.shared.snapshot(subsystems: selectedSubsystems, minLevel: minLevel)
        for subsystem in LogSubsystem.allCases {
            subsystemCounts[subsystem] = LogStore.shared.count(for: subsystem)
            subsystemLastTimes[subsystem] = LogStore.shared.lastEventTime(for: subsystem)
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func copyToClipboard() {
        let text = LogStore.shared.exportText(subsystems: selectedSubsystems, minLevel: minLevel)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
