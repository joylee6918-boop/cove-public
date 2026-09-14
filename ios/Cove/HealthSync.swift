import Foundation
import HealthKit

// Read-only HealthKit bridge. The system chooses what is readable; an empty result
// never means the app can infer that the user denied a specific permission.
@MainActor
final class HealthSync {
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private var onChange: (() async -> Void)?

    private var quantityTypes: [(HKQuantityTypeIdentifier, String, String, HKUnit, String)] {
        [(.stepCount, "steps", "步数", .count(), "步"),
         (.heartRate, "heartRate", "心率", .count().unitDivided(by: .minute()), "次/分"),
         (.restingHeartRate, "restingHeartRate", "静息心率", .count().unitDivided(by: .minute()), "次/分"),
         (.heartRateVariabilitySDNN, "hrv", "心率变异性", .secondUnit(with: .milli), "毫秒"),
         (.activeEnergyBurned, "activeEnergy", "活动能量", .kilocalorie(), "千卡"),
         (.appleExerciseTime, "exercise", "运动时间", .minute(), "分钟")]
    }

    private var types: Set<HKObjectType> {
        var result = Set<HKObjectType>(quantityTypes.compactMap { HKQuantityType.quantityType(forIdentifier: $0.0) })
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { result.insert(sleep) }
        return result
    }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "Cove", code: 1, userInfo: [NSLocalizedDescriptionKey: "此设备没有可用的 Apple Health 数据，请在 iPhone 上连接。"])
        }
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func snapshot() async -> HealthSnapshot {
        let now = Date()
        var metrics: [HealthMetric] = []
        if let sleep = await sleepMetric(at: now) { metrics.append(sleep) }
        for (identifier, id, title, unit, unitName) in quantityTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            let cumulative = ["steps", "activeEnergy", "exercise"].contains(id)
            if cumulative {
                if let value = await total(type, unit: unit, until: now) {
                    metrics.append(.init(id: id, title: title, value: value, unit: unitName, sampledAt: now, detail: "今日累计"))
                }
            } else if let sample = await latest(type, until: now) {
                metrics.append(.init(id: id, title: title, value: sample.quantity.doubleValue(for: unit), unit: unitName, sampledAt: sample.endDate, detail: "最近一次记录"))
            }
        }
        return .init(capturedAt: now, metrics: metrics)
    }

    func startObserving(onChange: @escaping () async -> Void) {
        self.onChange = onChange
        guard observers.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
        for case let type as HKSampleType in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    if let callback = self?.onChange { await callback() }
                    completion()
                }
            }
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    func stopObserving() {
        observers.forEach { store.stop($0) }
        observers.removeAll()
        onChange = nil
        store.disableAllBackgroundDelivery { _, _ in }
    }

    private func latest(_ type: HKQuantityType, until now: Date) async -> HKQuantitySample? {
        await withCheckedContinuation { continuation in
            let start = Calendar.current.date(byAdding: .day, value: -7, to: now)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictEndDate)
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKQuantitySample)
            })
        }
    }

    private func total(_ type: HKQuantityType, unit: HKUnit, until now: Date) async -> Double? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: now), end: now)
            store.execute(HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            })
        }
    }

    private func sleepMetric(at now: Date) async -> HealthMetric? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: now)!
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: results as? [HKCategorySample] ?? [])
            })
        }
        let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let intervals = samples.filter { asleep.contains($0.value) }.map { (max(start, $0.startDate), min(now, $0.endDate)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard var current = intervals.first else { return nil }
        var duration: TimeInterval = 0
        // Union overlapping device/source samples instead of double counting sleep.
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 { current.1 = max(current.1, interval.1) }
            else { duration += current.1.timeIntervalSince(current.0); current = interval }
        }
        duration += current.1.timeIntervalSince(current.0)
        return .init(id: "sleep", title: "睡眠", value: duration / 3600, unit: "小时", sampledAt: current.1, detail: "过去 24 小时的睡眠记录")
    }
}
