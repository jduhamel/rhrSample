Basically, you need to set a predicate to enable your window to be the Sleep Period.

```swift
func fetchSleepIntervals(completion: @escaping ([NSPredicate]?) -> Void) {
    let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .day, value: -1, to: Date())!

    let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
    let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

    let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, results, _ in
        guard let sleepSamples = results as? [HKCategorySample] else {
            completion(nil)
            return
        }

        // Filter for "Asleep" states only (ignore 'inBed' or 'awake')
        let asleepPredicates = sleepSamples.filter { $0.value != HKCategoryValueSleepAnalysis.awake.rawValue && $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
            .map { HKQuery.predicateForSamples(withStart: $0.startDate, end: $0.endDate, options: .strictStartDate) }

        completion(asleepPredicates)
    }
    HKHealthStore().execute(query)
}
```

And then query for those periods.


```swift
func fetchVitalsDuringSleep() {
    fetchSleepIntervals { sleepPredicates in
        guard let predicates = sleepPredicates, !predicates.isEmpty else { return }

        // Combine all sleep intervals into one "Overnight" predicate
        let overnightPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

        let vitalsToFetch = [
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!
        ]

        for type in vitalsToFetch {
            let query = HKSampleQuery(sampleType: type, predicate: overnightPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                guard let samples = results as? [HKQuantitySample] else { return }

                // Average the samples for that specific overnight period
                let unit = (type.identifier == HKQuantityTypeIdentifier.oxygenSaturation.rawValue) ? HKUnit.percent() : HKUnit(from: "count/min")
                let average = samples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: unit) } / Double(samples.count)

                print("Overnight \(type.identifier): \(average)")
            }
            HKHealthStore().execute(query)
        }
    }
}
```
