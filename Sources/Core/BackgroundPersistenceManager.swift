import BackgroundTasks
import CoreLocation
import UIKit

@MainActor
final class BackgroundPersistenceManager: NSObject, CLLocationManagerDelegate {
    static let refreshIdentifier = "com.quantswarm.alphazero.refresh"
    private static var didRegister = false

    private let locationManager = CLLocationManager()
    private var running = false
    private var refreshHandler: (@MainActor () async -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 100
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    func registerBackgroundTasks() {
        guard !Self.didRegister else { return }
        Self.didRegister = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(withSuccess: false)
                return
            }
            Task { @MainActor in
                await self?.handleBackgroundTask(refreshTask)
            }
        }
    }

    func setRefreshHandler(_ handler: @escaping @MainActor () async -> Void) {
        refreshHandler = handler
    }

    func start() {
        guard !running else { return }
        running = true
        scheduleNextRefresh()
        applyLocationAuthorization()
        UIApplication.shared.registerForRemoteNotifications()
    }

    func stop() {
        running = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
    }

    private func applyLocationAuthorization() {
        guard running else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            locationManager.stopUpdatingLocation()
        @unknown default:
            locationManager.stopUpdatingLocation()
        }
    }

    private func scheduleNextRefresh() {
        guard running else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("BGTaskScheduler submit failed: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        scheduleNextRefresh()
        guard running else {
            task.setTaskCompleted(withSuccess: false)
            return
        }
        let operation = Task { @MainActor in
            await refreshHandler?()
        }
        task.expirationHandler = {
            operation.cancel()
        }
        await operation.value
        task.setTaskCompleted(withSuccess: !operation.isCancelled)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.applyLocationAuthorization()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("Location update failed: \(error.localizedDescription)")
    }
}
