import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    metricRow("HealthKit", value: appState.authorizationStatus)
                    metricRow("Detected Wake Time", value: appState.formattedWakeTime)
                    metricRow("Apple Resting HR While Sleeping", value: appState.formattedAppleRestingHeartRate)
                    metricRow("Latest Apple Resting HR", value: appState.formattedAppleRestingHeartRateUnfiltered)
                    metricRow("Sleep Period Avg HR", value: appState.formattedSleepAverageHeartRate)
                    metricRow("Latest Refresh", value: appState.formattedLatestRefresh)
                    if let message = appState.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Actions") {
                    Button("Request Health Access") {
                        Task {
                            await appState.requestAuthorization()
                        }
                    }

                    Button("Refresh Now") {
                        Task {
                            await appState.refreshNow()
                        }
                    }
                }

                Section("Recent Runs") {
                    if appState.runHistory.isEmpty {
                        Text("No hourly runs yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.runHistory) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.timestamp.formatted(date: .abbreviated, time: .shortened))
                                Text(run.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Morning RHR")
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
