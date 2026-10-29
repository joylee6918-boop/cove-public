import Foundation
import HealthKit

@MainActor
protocol CoveHealthReading {
    func authorize(metrics: Set<String>) async throws
    func snapshot(metrics: Set<String>, startAt: Date?, endAt: Date) async throws -> HealthSnapshot
    func startObserving(metrics: Set<String>, onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

extension CoveHealthReading {
    func startObserving(metrics: Set<String>, onChange: @escaping @MainActor () -> Void) {}
}

/// Read-only HealthKit adapter. Foreground observers are started only after a
/// standing service grant; no background delivery or network side effects here.
@MainActor
final class HealthSync: CoveHealthReading {
    private let store = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    private var observedMetrics: Set<String> = []

    private struct QuantityDefinition {
        let identifier: HKQuantityTypeIdentifier
        let id: String
        let unit: HKUnit
        let unitName: String
        let cumulative: Bool
        let scale: Double
    }

    private var quantityTypes: [QuantityDefinition] {
        [
            .init(identifier: .stepCount, id: "steps", unit: .count(), unitName: "步", cumulative: true, scale: 1),
            .init(identifier: .heartRate, id: "heartRate", unit: .count().unitDivided(by: .minute()), unitName: "次/分", cumulative: false, scale: 1),
            .init(identifier: .restingHeartRate, id: "restingHeartRate", unit: .count().unitDivided(by: .minute()), unitName: "次/分", cumulative: false, scale: 1),
            .init(identifier: .walkingHeartRateAverage, id: "walkingHeartRate", unit: .count().unitDivided(by: .minute()), unitName: "次/分", cumulative: false, scale: 1),
            .init(identifier: .heartRateRecoveryOneMinute, id: "heartRateRecovery", unit: .count().unitDivided(by: .minute()), unitName: "次/分", cumulative: false, scale: 1),
            .init(identifier: .heartRateVariabilitySDNN, id: "hrv", unit: .secondUnit(with: .milli), unitName: "毫秒", cumulative: false, scale: 1),
            .init(identifier: .oxygenSaturation, id: "oxygenSaturation", unit: .percent(), unitName: "%", cumulative: false, scale: 100),
            .init(identifier: .respiratoryRate, id: "respiratoryRate", unit: .count().unitDivided(by: .minute()), unitName: "次/分", cumulative: false, scale: 1),
            .init(identifier: .vo2Max, id: "vo2Max", unit: HKUnit(from: "ml/kg*min"), unitName: "毫升/千克/分钟", cumulative: false, scale: 1),
            .init(identifier: .bodyMass, id: "bodyMass", unit: .gramUnit(with: .kilo), unitName: "千克", cumulative: false, scale: 1),
            .init(identifier: .height, id: "height", unit: .meterUnit(with: .centi), unitName: "厘米", cumulative: false, scale: 1),
            .init(identifier: .bodyMassIndex, id: "bodyMassIndex", unit: .count(), unitName: "", cumulative: false, scale: 1),
            .init(identifier: .bodyFatPercentage, id: "bodyFatPercentage", unit: .percent(), unitName: "%", cumulative: false, scale: 100),
            .init(identifier: .bloodPressureSystolic, id: "bloodPressureSystolic", unit: .millimeterOfMercury(), unitName: "毫米汞柱", cumulative: false, scale: 1),
            .init(identifier: .bloodPressureDiastolic, id: "bloodPressureDiastolic", unit: .millimeterOfMercury(), unitName: "毫米汞柱", cumulative: false, scale: 1),
            .init(identifier: .bloodGlucose, id: "bloodGlucose", unit: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter()), unitName: "毫摩尔/升", cumulative: false, scale: 1),
            .init(identifier: .bodyTemperature, id: "bodyTemperature", unit: .degreeCelsius(), unitName: "摄氏度", cumulative: false, scale: 1),
            .init(identifier: .appleSleepingWristTemperature, id: "sleepingWristTemperature", unit: .degreeCelsius(), unitName: "摄氏度", cumulative: false, scale: 1),
            .init(identifier: .activeEnergyBurned, id: "activeEnergy", unit: .kilocalorie(), unitName: "千卡", cumulative: true, scale: 1),
            .init(identifier: .basalEnergyBurned, id: "basalEnergy", unit: .kilocalorie(), unitName: "千卡", cumulative: true, scale: 1),
            .init(identifier: .appleExerciseTime, id: "exerciseTime", unit: .minute(), unitName: "分钟", cumulative: true, scale: 1),
            .init(identifier: .appleStandTime, id: "standTime", unit: .minute(), unitName: "分钟", cumulative: true, scale: 1),
            .init(identifier: .distanceWalkingRunning, id: "walkingRunningDistance", unit: .meterUnit(with: .kilo), unitName: "公里", cumulative: true, scale: 1),
            .init(identifier: .distanceCycling, id: "cyclingDistance", unit: .meterUnit(with: .kilo), unitName: "公里", cumulative: true, scale: 1),
            .init(identifier: .flightsClimbed, id: "flightsClimbed", unit: .count(), unitName: "层", cumulative: true, scale: 1),
            .init(identifier: .dietaryWater, id: "dietaryWater", unit: .liter(), unitName: "升", cumulative: true, scale: 1)
        ]
    }

    func authorize(metrics: Set<String> = CoveHealthScope.metricIDs) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "Cove", code: 1, userInfo: [NSLocalizedDescriptionKey: "此设备没有可用的 Apple 健康数据，请在 iPhone 上读取。"])
        }
        var types = Set<HKObjectType>(quantityTypes.filter { metrics.contains($0.id) }.compactMap { HKQuantityType.quantityType(forIdentifier: $0.identifier) })
        if !metrics.isDisjoint(with: Self.sleepMetricIDs), let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if !metrics.isDisjoint(with: Self.workoutMetricIDs) { types.insert(HKObjectType.workoutType()) }
        guard !types.isEmpty else { return }
        // HealthKit decides whether a system sheet is still needed. An already
        // established OS authorization is not asked for again on each refresh.
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: types)
        if status != .unnecessary { try await store.requestAuthorization(toShare: [], read: types) }
    }

    /// Missing or denied values are omitted, never converted to zero. Manual reads use
    /// today for cumulative values, 24h for sleep, and 7d for point/workout values.
    func snapshot(metrics selected: Set<String> = CoveHealthScope.metricIDs, startAt: Date? = nil, endAt: Date = Date()) async throws -> HealthSnapshot {
        var metrics: [HealthMetric] = []
        var sleepSegments: [CoveSleepSegment]?
        var workouts: [CoveWorkout]?
        if !selected.isDisjoint(with: Self.sleepMetricIDs) {
            if let sleep = try? await sleepData(selected: selected, start: startAt ?? endAt.addingTimeInterval(-86400), end: endAt) {
                metrics += sleep.metrics
                sleepSegments = sleep.segments
            }
        }
        for definition in quantityTypes where selected.contains(definition.id) {
            guard let type = HKQuantityType.quantityType(forIdentifier: definition.identifier) else { continue }
            let start = startAt ?? (definition.cumulative ? Calendar.current.startOfDay(for: endAt) : endAt.addingTimeInterval(-7 * 86400))
            guard let sample = try? await latest(type, start: start, end: endAt) else { continue }
            let raw: Double?
            if definition.cumulative {
                raw = try? await total(type, unit: definition.unit, start: start, end: endAt)
            } else {
                raw = sample.quantity.doubleValue(for: definition.unit)
            }
            guard let raw else { continue }
            metrics.append(.init(id: definition.id, title: CoveHealthScope.title(definition.id), value: raw * definition.scale, unit: definition.unitName, sampledAt: sample.endDate, detail: definition.cumulative ? (startAt == nil ? "今日累计" : "请求时段累计") : "所选时段内最近记录；不是实时测量", source: definition.cumulative ? "Apple 健康（系统汇总）" : sample.sourceRevision.source.name))
        }
        if !selected.isDisjoint(with: Self.workoutMetricIDs) {
            if let fitness = try? await workoutData(selected: selected, start: startAt ?? endAt.addingTimeInterval(-7 * 86400), end: endAt) {
                metrics += fitness.metrics
                workouts = fitness.workouts
            }
        }
        return .init(capturedAt: Date(), metrics: metrics, sleepSegments: sleepSegments, workouts: workouts)
    }

    func startObserving(metrics: Set<String>, onChange: @escaping @MainActor () -> Void) {
        guard observedMetrics != metrics || observerQueries.isEmpty else { return }
        stopObserving()
        observedMetrics = metrics
        var types: [HKSampleType] = quantityTypes.filter { metrics.contains($0.id) }
            .compactMap { HKQuantityType.quantityType(forIdentifier: $0.identifier) }
        if !metrics.isDisjoint(with: Self.sleepMetricIDs), let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.append(type) }
        if !metrics.isDisjoint(with: Self.workoutMetricIDs) { types.append(.workoutType()) }
        observerQueries = types.map { type in
            HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                completion()
                guard error == nil else { return }
                Task { @MainActor in onChange() }
            }
        }
        observerQueries.forEach { store.execute($0) }
    }

    func stopObserving() {
        observerQueries.forEach { store.stop($0) }
        observerQueries = []
        observedMetrics = []
        store.disableAllBackgroundDelivery { _, _ in }
    }

    private static let sleepMetricIDs: Set<String> = ["sleep", "sleepAwake", "sleepCore", "sleepDeep", "sleepREM", "sleepUnspecified"]
    private static let workoutMetricIDs: Set<String> = ["workoutCount", "workoutDuration"]

    private func latest(_ type: HKQuantityType, start: Date, end: Date) async throws -> HKQuantitySample? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples?.first as? HKQuantitySample) }
            })
        }
    }

    private func total(_ type: HKQuantityType, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            store.execute(HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit)) }
            })
        }
    }

    private func sleepData(selected: Set<String>, start: Date, end: Date) async throws -> (metrics: [HealthMetric], segments: [CoveSleepSegment]) {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return ([], []) }
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results as? [HKCategorySample] ?? []) }
            })
        }
        let stages: [(String, Int)] = [
            ("sleepAwake", HKCategoryValueSleepAnalysis.awake.rawValue),
            ("sleepCore", HKCategoryValueSleepAnalysis.asleepCore.rawValue),
            ("sleepDeep", HKCategoryValueSleepAnalysis.asleepDeep.rawValue),
            ("sleepREM", HKCategoryValueSleepAnalysis.asleepREM.rawValue),
            ("sleepUnspecified", HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue)
        ]
        let asleep = Set(stages.dropFirst().map(\.1))
        var result: [HealthMetric] = []
        if selected.contains("sleep"), let metric = durationMetric(id: "sleep", samples: samples.filter { asleep.contains($0.value) }, start: start, end: end, detail: "所选时段睡眠合计（重叠记录已去重）") { result.append(metric) }
        for (id, value) in stages where selected.contains(id) {
            if let metric = durationMetric(id: id, samples: samples.filter { $0.value == value }, start: start, end: end, detail: "所选时段阶段合计（重叠记录已去重）") { result.append(metric) }
        }
        let valueToID = Dictionary(uniqueKeysWithValues: stages.map { ($0.1, $0.0) })
        let rawSegments = samples.compactMap { sample -> CoveSleepSegment? in
            guard let stageID = valueToID[sample.value], selected.contains("sleep") || selected.contains(stageID) else { return nil }
            let clippedStart = max(start, sample.startDate), clippedEnd = min(end, sample.endDate)
            guard clippedEnd > clippedStart else { return nil }
            return .init(stageID: stageID, startAt: clippedStart, endAt: clippedEnd, source: safeSource(sample.sourceRevision.source.name))
        }.sorted { $0.startAt < $1.startAt }
        var segmentKeys = Set<String>()
        let segments = rawSegments.filter { segmentKeys.insert($0.id).inserted }
        guard segments.count <= 5000 else {
            throw NSError(domain: "Cove", code: 2, userInfo: [NSLocalizedDescriptionKey: "睡眠阶段记录过多，未生成不完整摘要。"])
        }
        return (result, segments)
    }

    private func durationMetric(id: String, samples: [HKCategorySample], start: Date, end: Date, detail: String) -> HealthMetric? {
        let intervals = samples.map { (max(start, $0.startDate), min(end, $0.endDate)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard var current = intervals.first else { return nil }
        var duration: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 { current.1 = max(current.1, interval.1) }
            else { duration += current.1.timeIntervalSince(current.0); current = interval }
        }
        duration += current.1.timeIntervalSince(current.0)
        let sources = Set(samples.map { $0.sourceRevision.source.name }).sorted().joined(separator: "、")
        return .init(id: id, title: CoveHealthScope.title(id), value: duration / 3600, unit: "小时", sampledAt: current.1, detail: detail, source: sources)
    }

    private func workoutData(selected: Set<String>, start: Date, end: Date) async throws -> (metrics: [HealthMetric], workouts: [CoveWorkout]) {
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            store.execute(HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results as? [HKWorkout] ?? []) }
            })
        }
        guard let sampledAt = workouts.map(\.endDate).max() else { return ([], []) }
        var result: [HealthMetric] = []
        if selected.contains("workoutCount") { result.append(.init(id: "workoutCount", title: CoveHealthScope.title("workoutCount"), value: Double(workouts.count), unit: "次", sampledAt: sampledAt, detail: "请求时段内健身记录数量", source: "Apple 健康（健身记录汇总）")) }
        if selected.contains("workoutDuration") { result.append(.init(id: "workoutDuration", title: CoveHealthScope.title("workoutDuration"), value: workouts.reduce(0) { $0 + $1.duration } / 60, unit: "分钟", sampledAt: sampledAt, detail: "请求时段内健身记录总时长", source: "Apple 健康（健身记录汇总）")) }
        let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        let distanceIdentifiers: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        let distanceTypes = distanceIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
        guard workouts.count <= 200 else {
            throw NSError(domain: "Cove", code: 3, userInfo: [NSLocalizedDescriptionKey: "健身记录过多，未生成不完整摘要。"])
        }
        let details = workouts.sorted { $0.startDate > $1.startDate }.map { workout in
            let energy = activeEnergy.flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }
            let distance = distanceTypes.compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }.reduce(0, +)
            return CoveWorkout(id: workout.uuid.uuidString, type: workoutName(workout.workoutActivityType), startAt: workout.startDate, endAt: workout.endDate, durationSeconds: workout.duration, energyKcal: energy, distanceMeters: distance > 0 ? distance : nil, source: safeSource(workout.sourceRevision.source.name))
        }
        return (result, details)
    }

    private func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "步行"
        case .running: return "跑步"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .pilates: return "普拉提"
        case .functionalStrengthTraining: return "功能性力量训练"
        case .traditionalStrengthTraining: return "传统力量训练"
        case .highIntensityIntervalTraining: return "高强度间歇训练"
        case .dance: return "舞蹈"
        case .elliptical: return "椭圆机"
        case .stairClimbing: return "爬楼训练"
        case .rowing: return "划船"
        case .coreTraining: return "核心训练"
        case .flexibility: return "柔韧训练"
        default: return "其他健身（\(type.rawValue)）"
        }
    }

    private func safeSource(_ source: String) -> String {
        String(String.UnicodeScalarView(source.unicodeScalars.filter { $0.value >= 32 })).prefix(120).description
    }
}
