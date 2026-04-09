import BackgroundTasks
import Foundation

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let taskIdentifier = "com.example.rhrApp.hourlyRefresh"
    private weak var appState: AppState?

    private init() {}

    func attach(appState: AppState) {
        self.appState = appState
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            self.handle(task: task as! BGAppRefreshTask)
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Calendar.current.nextTopOfHour(after: Date())

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }

    private func handle(task: BGAppRefreshTask) {
        scheduleNextRefresh()

        let work = Task {
            await appState?.runHourlyRefreshIfNeeded()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}

private extension Calendar {
    func nextTopOfHour(after date: Date) -> Date {
        let nextHour = self.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        return self.dateInterval(of: .hour, for: nextHour)?.start ?? nextHour
    }
}
