import Foundation
import HealthKit
import Combine

@MainActor
final class HealthKitManager: ObservableObject {
    @Published var authorizationMessage = "未連携"
    private let store = HKHealthStore()

    private var stepType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .stepCount) }
    private var heartType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .heartRate) }
    private var energyType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) }
    private var distanceType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppError.message("この端末ではHealthKitを利用できません") }
        let share: Set<HKSampleType> = Set([HKObjectType.workoutType(), distanceType].compactMap { $0 })
        let read: Set<HKObjectType> = Set([stepType, heartType, energyType].compactMap { $0 })
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: share, read: read) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: AppError.message("HealthKitの許可が必要です")) }
            }
        }
        authorizationMessage = "HealthKit連携済み"
    }

    func write(route: SavedRoute) async {
        guard !route.imported, route.deletedAt == nil, route.distanceMeters > 0 else { return }
        let distance = HKQuantity(unit: .meter(), doubleValue: route.distanceMeters)
        let workout = HKWorkout(
            activityType: .walking,
            start: route.startedDate,
            end: route.endedDate,
            workoutEvents: nil,
            totalEnergyBurned: nil,
            totalDistance: distance,
            device: .local(),
            metadata: ["sanporoad_route_id": String(route.id)]
        )
        do {
            try await save(workout)
            if let distanceType {
                let sample = HKQuantitySample(type: distanceType, quantity: distance, start: route.startedDate, end: route.endedDate, metadata: ["sanporoad_route_id": String(route.id)])
                try await save(sample)
            }
        } catch { }
    }

    func summary(route: SavedRoute) async -> HealthSummary {
        let start = route.startedDate, end = route.endedDate
        async let steps = statistic(type: stepType, option: .cumulativeSum, start: start, end: end, unit: .count())
        async let heart = statistic(type: heartType, option: .discreteAverage, start: start, end: end, unit: HKUnit.count().unitDivided(by: .minute()))
        async let energy = statistic(type: energyType, option: .cumulativeSum, start: start, end: end, unit: .kilocalorie())
        return await HealthSummary(steps: steps, averageHeartRate: heart, activeCalories: energy)
    }

    private func save(_ object: HKObject) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(object) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: AppError.message("HealthKitへ保存できませんでした")) }
            }
        }
    }

    private func statistic(type: HKQuantityType?, option: HKStatisticsOptions, start: Date, end: Date, unit: HKUnit) async -> Double? {
        guard let type else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: option) { _, result, _ in
                let quantity: HKQuantity?
                if option == .cumulativeSum { quantity = result?.sumQuantity() }
                else { quantity = result?.averageQuantity() }
                continuation.resume(returning: quantity?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}
