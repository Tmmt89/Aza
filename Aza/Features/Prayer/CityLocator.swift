import CoreLocation
import Combine

/// Определение города по геопозиции (§4.2) — только по явному действию
/// пользователя, никогда само по себе.
///
/// Координаты нигде не сохраняются (§12): из фикса сразу получается
/// ближайший ГОРОДСКОЙ ПРОФИЛЬ (у него есть часовой пояс и мазхаб), а сам
/// фикс отбрасывается. Профиль не выдаётся за «ваш город»: показываем
/// расстояние, решение остаётся за пользователем.
@MainActor
final class CityLocator: NSObject, ObservableObject {

    struct Match {
        let city: PrayerCity
        let distanceKilometers: Int
    }

    enum State: Equatable {
        case idle
        case locating
        case found(cityID: String, distanceKilometers: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let manager: CLLocationManager
    private let servicesEnabled: () -> Bool
    private let requestTimeout: TimeInterval
    private var timeoutTimer: Timer?
    private var continuation: CheckedContinuation<Match?, Never>?
    private var didRequestLocation = false

    init(manager: CLLocationManager = CLLocationManager(),
         servicesEnabled: @escaping () -> Bool = { CLLocationManager.locationServicesEnabled() },
         requestTimeout: TimeInterval = 60) {
        self.manager = manager
        self.servicesEnabled = servicesEnabled
        self.requestTimeout = requestTimeout
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Один запрос позиции. Возвращает ближайший профиль или nil.
    /// Повторный вызов во время работы не создаёт вторую попытку:
    /// иначе первый вызывающий навсегда остался бы без ответа.
    func locate() async -> Match? {
        guard continuation == nil else { return nil }
        if let unavailable = Self.unavailableState(manager.authorizationStatus,
                                                    servicesEnabled: servicesEnabled()) {
            state = unavailable
            return nil
        }
        state = .locating
        return await withCheckedContinuation { continuation in
            // Сначала сохраняем ожидание: ответ разрешения может прийти сразу.
            self.continuation = continuation
            let timer = Timer(timeInterval: requestTimeout, repeats: false) { [weak self] _ in
                azaAssumeMainUnchecked {
                    guard let self, self.continuation != nil else { return }
                    self.state = .failed("Не удалось определить город — повторите попытку или выберите его вручную")
                    self.finish(nil)
                }
            }
            timeoutTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                requestLocationIfNeeded()
            }
        }
    }

    static func unavailableState(_ authorization: CLAuthorizationStatus,
                                 servicesEnabled: Bool) -> State? {
        if !servicesEnabled {
            return .failed("Службы геолокации выключены на Mac — включите их в Системных настройках → Конфиденциальность и безопасность → Службы геолокации")
        }
        switch authorization {
        case .denied:
            return .failed("Нет доступа к геопозиции — разрешите его для Aza в Системных настройках → Конфиденциальность и безопасность → Службы геолокации")
        case .restricted:
            return .failed("Доступ к геопозиции ограничен системой — выберите город вручную")
        default:
            return nil
        }
    }

    private func finish(_ match: Match?) {
        let pending = continuation
        continuation = nil
        didRequestLocation = false
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        manager.stopUpdatingLocation()
        pending?.resume(returning: match)
    }

    private func requestLocationIfNeeded() {
        guard continuation != nil, !didRequestLocation else { return }
        didRequestLocation = true
        manager.requestLocation()
    }

    /// Ближайший город из списка профилей.
    private func nearestCity(to location: CLLocation) -> Match? {
        // Города без координат в сравнении не участвуют — расстояние до
        // них неизвестно.
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        let candidates = PrayerStore.cities.compactMap {
            city -> (PrayerCity, CLLocationDistance)? in
            guard let latitude = city.latitude, let longitude = city.longitude else {
                return nil
            }
            let target = CLLocation(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(target.coordinate) else { return nil }
            let distance = location.distance(from: target)
            guard distance.isFinite, distance >= 0 else { return nil }
            return (city, distance)
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        return Match(city: best.0, distanceKilometers: Int((best.1 / 1000).rounded()))
    }
}

extension CityLocator: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        azaAssumeMainUnchecked {
            guard continuation != nil else { return }
            if let unavailable = Self.unavailableState(manager.authorizationStatus,
                                                        servicesEnabled: servicesEnabled()) {
                state = unavailable
                finish(nil)
            } else if manager.authorizationStatus != .notDetermined {
                requestLocationIfNeeded()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        azaAssumeMainUnchecked {
            // Ответ отменённого или истёкшего запроса не меняет город.
            guard continuation != nil else { return }
            // Устаревшие и невалидные фиксы отбрасываем.
            guard let location = locations.last,
                  location.horizontalAccuracy >= 0,
                  abs(location.timestamp.timeIntervalSinceNow) < 120,
                  let match = nearestCity(to: location) else {
                state = .failed("Не удалось определить местоположение")
                finish(nil)
                return
            }
            state = .found(cityID: match.city.id,
                           distanceKilometers: match.distanceKilometers)
            finish(match)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        azaAssumeMainUnchecked {
            guard continuation != nil else { return }
            state = Self.unavailableState(manager.authorizationStatus,
                                           servicesEnabled: servicesEnabled())
                ?? .failed(error.localizedDescription)
            finish(nil)
        }
    }
}
