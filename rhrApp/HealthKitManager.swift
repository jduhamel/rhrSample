import Foundation
import HealthKit

struct MorningMetrics {
    let wakeTime: Date
    let appleRestingHeartRate: Double?
    let latestAppleRestingHeartRate: Double?
    let sleepAverageHeartRate: Double?
}

final class HealthKitManager {
    private let healthStore = HKHealthStore()
    private let calendar = Calendar.current

    func authorizationSummary() -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "Health data unavailable"
        }

        guard
            let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            let restingType = HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else {
            return "Required HealthKit types unavailable"
        }

        let statuses = [
            healthStore.authorizationStatus(for: sleepType),
            healthStore.authorizationStatus(for: restingType),
            healthStore.authorizationStatus(for: heartRateType)
        ]

        if statuses.allSatisfy({ $0 == .sharingAuthorized }) {
            return "Authorized"
        }

        if statuses.contains(.sharingDenied) {
            return "Denied"
        }

        return "Not determined"
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.unavailable
        }

        guard
            let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            let restingType = HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else {
            throw HealthKitError.missingType
        }

        let readTypes: Set<HKObjectType> = [sleepType, restingType, heartRateType]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: HealthKitError.authorizationFailed)
                }
            }
        }
    }

    func loadMorningMetrics(referenceDate: Date = Date()) async throws -> MorningMetrics? {
        let sleepSession = try await fetchLatestSleepSession(endingBefore: referenceDate)
        guard let sleepSession else {
            return nil
        }

        async let appleRestingHeartRate = fetchLatestRestingHeartRate(predicates: sleepSession.predicates)
        async let latestAppleRestingHeartRate = fetchLatestRestingHeartRate(before: referenceDate)
        async let sleepAverageHeartRate = fetchSleepAverageHeartRate(predicates: sleepSession.predicates)

        return try await MorningMetrics(
            wakeTime: sleepSession.wakeTime,
            appleRestingHeartRate: appleRestingHeartRate,
            latestAppleRestingHeartRate: latestAppleRestingHeartRate,
            sleepAverageHeartRate: sleepAverageHeartRate
        )
    }

    private func fetchLatestSleepSession(endingBefore referenceDate: Date) async throws -> SleepSession? {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitError.missingType
        }

        let startDate = calendar.date(byAdding: .hour, value: -24, to: referenceDate) ?? referenceDate.addingTimeInterval(-86_400)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: referenceDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let samples = try await querySamples(
            sampleType: sleepType,
            predicate: predicate,
            sortDescriptors: [sortDescriptor]
        ) as? [HKCategorySample] ?? []

        let asleepSamples = samples
            .filter(Self.isAsleepSample)
            .sorted { $0.endDate > $1.endDate }

        guard let latest = asleepSamples.first else {
            return nil
        }

        var groupedSamples = [latest]
        var cursorStart = latest.startDate

        for sample in asleepSamples.dropFirst() {
            let gap = cursorStart.timeIntervalSince(sample.endDate)
            if gap <= 7_200 {
                groupedSamples.append(sample)
                cursorStart = min(cursorStart, sample.startDate)
            } else {
                break
            }
        }

        let predicates = groupedSamples.map {
            HKQuery.predicateForSamples(withStart: $0.startDate, end: $0.endDate, options: .strictStartDate)
        }

        return SleepSession(wakeTime: latest.endDate, predicates: predicates)
    }

    private func fetchLatestRestingHeartRate(before referenceDate: Date) async throws -> Double? {
        guard let restingType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            throw HealthKitError.missingType
        }

        let startDate = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate.addingTimeInterval(-604_800)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: referenceDate, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let samples = try await querySamples(
            sampleType: restingType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) as? [HKQuantitySample] ?? []

        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.first?.quantity.doubleValue(for: unit)
    }

    private func fetchLatestRestingHeartRate(predicates: [NSPredicate]) async throws -> Double? {
        guard let restingType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            throw HealthKitError.missingType
        }

        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let samples = try await querySamples(
            sampleType: restingType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) as? [HKQuantitySample] ?? []

        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.first?.quantity.doubleValue(for: unit)
    }

    private func fetchSleepAverageHeartRate(predicates: [NSPredicate]) async throws -> Double? {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitError.missingType
        }

        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        let samples = try await querySamples(
            sampleType: heartRateType,
            predicate: predicate,
            sortDescriptors: nil
        ) as? [HKQuantitySample] ?? []

        guard !samples.isEmpty else {
            return nil
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let total = samples.reduce(0.0) { partialResult, sample in
            partialResult + sample.quantity.doubleValue(for: unit)
        }
        return total / Double(samples.count)
    }

    private func querySamples(
        sampleType: HKSampleType,
        predicate: NSPredicate?,
        limit: Int = HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor]?
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private static func isAsleepSample(_ sample: HKCategorySample) -> Bool {
        sample.value != HKCategoryValueSleepAnalysis.awake.rawValue &&
        sample.value != HKCategoryValueSleepAnalysis.inBed.rawValue
    }
}

private struct SleepSession {
    let wakeTime: Date
    let predicates: [NSPredicate]
}

enum HealthKitError: LocalizedError {
    case unavailable
    case missingType
    case authorizationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is unavailable on this device."
        case .missingType:
            return "One or more required HealthKit data types are unavailable."
        case .authorizationFailed:
            return "HealthKit authorization did not complete successfully."
        }
    }
}
