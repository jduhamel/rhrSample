import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var authorizationStatus = "Unknown"
    @Published private(set) var latestWakeTime: Date?
    @Published private(set) var latestAppleRestingHeartRate: Double?
    @Published private(set) var latestAppleRestingHeartRateUnfiltered: Double?
    @Published private(set) var latestSleepAverageHeartRate: Double?
    @Published private(set) var latestRefresh: Date?
    @Published private(set) var runHistory: [RunRecord] = []
    @Published private(set) var statusMessage: String?

    private let healthKitManager = HealthKitManager()
    private let storage = RunHistoryStore()
    private var lastProcessedHour: Date?

    var formattedWakeTime: String {
        latestWakeTime?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable"
    }

    var formattedAppleRestingHeartRate: String {
        Self.formatBPM(latestAppleRestingHeartRate)
    }

    var formattedAppleRestingHeartRateUnfiltered: String {
        Self.formatBPM(latestAppleRestingHeartRateUnfiltered)
    }

    var formattedSleepAverageHeartRate: String {
        Self.formatBPM(latestSleepAverageHeartRate)
    }

    var formattedLatestRefresh: String {
        latestRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    func bootstrap() async {
        loadPersistedState()
        BackgroundTaskManager.shared.attach(appState: self)
        BackgroundTaskManager.shared.scheduleNextRefresh()
        await refreshAuthorizationStatus()
    }

    func requestAuthorization() async {
        do {
            try await healthKitManager.requestAuthorization()
            authorizationStatus = "Authorized"
            statusMessage = "Health access granted."
            await refreshNow()
        } catch {
            authorizationStatus = "Unavailable"
            statusMessage = error.localizedDescription
        }
    }

    func refreshNow() async {
        await runRefresh(trigger: "Manual refresh", enforceMorningWindow: false)
    }

    func runHourlyRefreshIfNeeded() async {
        await runRefresh(trigger: "Background refresh", enforceMorningWindow: true)
    }

    private func runRefresh(trigger: String, enforceMorningWindow: Bool) async {
        do {
            let metrics = try await healthKitManager.loadMorningMetrics()
            latestRefresh = Date()

            guard let metrics else {
                statusMessage = "No sleep session found in the last 24 hours."
                persist()
                return
            }

            latestWakeTime = metrics.wakeTime

            if enforceMorningWindow {
                let now = Date()
                guard now >= metrics.wakeTime else {
                    statusMessage = "\(trigger): skipped because the latest sleep session has not ended yet."
                    persist()
                    return
                }

                guard !Calendar.current.isAfterTenAM(now) else {
                    statusMessage = "\(trigger): skipped because it is after 10:00 AM."
                    persist()
                    return
                }

                let hourSlot = Calendar.current.dateInterval(of: .hour, for: now)?.start
                if hourSlot == lastProcessedHour {
                    statusMessage = "\(trigger): skipped because this hour was already processed."
                    persist()
                    return
                }
                lastProcessedHour = hourSlot
            }

            latestAppleRestingHeartRate = metrics.appleRestingHeartRate
            latestAppleRestingHeartRateUnfiltered = metrics.latestAppleRestingHeartRate
            latestSleepAverageHeartRate = metrics.sleepAverageHeartRate
            statusMessage = "\(trigger): updated main view."
            prependRun(
                timestamp: latestRefresh ?? Date(),
                wakeTime: metrics.wakeTime,
                appleRestingHeartRate: metrics.appleRestingHeartRate,
                sleepAverageHeartRate: metrics.sleepAverageHeartRate,
                message: statusMessage ?? trigger
            )
            persist()
        } catch {
            latestRefresh = Date()
            statusMessage = "\(trigger): \(error.localizedDescription)"
            persist()
        }
    }

    private func refreshAuthorizationStatus() async {
        authorizationStatus = healthKitManager.authorizationSummary()
    }

    private func loadPersistedState() {
        guard let persisted = storage.load() else {
            return
        }

        latestWakeTime = persisted.latestWakeTime
        latestAppleRestingHeartRate = persisted.latestAppleRestingHeartRate
        latestAppleRestingHeartRateUnfiltered = persisted.latestAppleRestingHeartRateUnfiltered
        latestSleepAverageHeartRate = persisted.latestSleepAverageHeartRate
        latestRefresh = persisted.latestRefresh
        runHistory = persisted.runHistory
        lastProcessedHour = persisted.lastProcessedHour
        statusMessage = persisted.statusMessage
    }

    private func persist() {
        let persisted = PersistedState(
            latestWakeTime: latestWakeTime,
            latestAppleRestingHeartRate: latestAppleRestingHeartRate,
            latestAppleRestingHeartRateUnfiltered: latestAppleRestingHeartRateUnfiltered,
            latestSleepAverageHeartRate: latestSleepAverageHeartRate,
            latestRefresh: latestRefresh,
            runHistory: runHistory,
            lastProcessedHour: lastProcessedHour,
            statusMessage: statusMessage
        )
        storage.save(persisted)
    }

    private func prependRun(
        timestamp: Date,
        wakeTime: Date,
        appleRestingHeartRate: Double?,
        sleepAverageHeartRate: Double?,
        message: String
    ) {
        let run = RunRecord(
            timestamp: timestamp,
            wakeTime: wakeTime,
            appleRestingHeartRate: appleRestingHeartRate,
            sleepAverageHeartRate: sleepAverageHeartRate,
            message: message
        )
        runHistory = Array(([run] + runHistory).prefix(12))
    }

    private static func formatBPM(_ value: Double?) -> String {
        guard let value else {
            return "Unavailable"
        }

        return "\(Int(value.rounded())) bpm"
    }
}

struct RunRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let wakeTime: Date
    let appleRestingHeartRate: Double?
    let sleepAverageHeartRate: Double?
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        wakeTime: Date,
        appleRestingHeartRate: Double?,
        sleepAverageHeartRate: Double?,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.wakeTime = wakeTime
        self.appleRestingHeartRate = appleRestingHeartRate
        self.sleepAverageHeartRate = sleepAverageHeartRate
        self.message = message
    }

    var summary: String {
        let appleText = appleRestingHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "n/a"
        let sleepText = sleepAverageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "n/a"
        return "Wake \(wakeTime.formatted(date: .omitted, time: .shortened)) | Apple RHR \(appleText) | Sleep avg \(sleepText)"
    }
}

struct PersistedState: Codable {
    let latestWakeTime: Date?
    let latestAppleRestingHeartRate: Double?
    let latestAppleRestingHeartRateUnfiltered: Double?
    let latestSleepAverageHeartRate: Double?
    let latestRefresh: Date?
    let runHistory: [RunRecord]
    let lastProcessedHour: Date?
    let statusMessage: String?
}

private extension Calendar {
    func isAfterTenAM(_ date: Date) -> Bool {
        guard let tenAM = self.date(bySettingHour: 10, minute: 0, second: 0, of: date) else {
            return false
        }

        return date >= tenAM
    }
}
