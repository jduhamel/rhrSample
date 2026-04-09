import Foundation

struct RunHistoryStore {
    private let fileManager = FileManager.default
    private let fileName = "morning-rhr-state.json"

    func load() -> PersistedState? {
        guard let url = stateURL(), let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        guard let url = stateURL() else {
            return
        }

        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to persist run history: \(error.localizedDescription)")
        }
    }

    private func stateURL() -> URL? {
        try? fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(fileName)
    }
}
