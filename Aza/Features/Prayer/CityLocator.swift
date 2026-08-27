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
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Match?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Один запрос позиции. Возвращает ближайший профиль или nil.
    /// Повторный вызов во время работы не создаёт вторую попытку:
    /// иначе первый вызывающий навсегда остался бы без ответа.
    func locate() async -> Match? {
        guard continuation == nil else { return nil }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            state = .denied
            return nil
        case .notDetermined:
            state = .locating
            manager.requestWhenInUseAuthorization()
            // Продолжим в делегате, когда пользователь ответит.
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        default:
            state = .locating
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                manager.requestLocation()
            }
        }
    }

    private func finish(_ match: Match?) {
        continuation?.resume(returning: match)
        continuation = nil
    }

    /// Ближайший город из списка профилей.
    private func nearestCity(to location: CLLocation) -> Match? {
        let candidates = PrayerStore.cities.map { city -> (PrayerCity, CLLocationDistance) in
            let target = CLLocation(latitude: city.latitude, longitude: city.longitude)
            return (city, location.distance(from: target))
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        return Match(city: best.0, distanceKilometers: Int((best.1 / 1000).rounded()))
    }
}

extension CityLocator: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .authorized, .authorizedAlways:
                guard continuation != nil else { return }
                manager.requestLocation()
            case .denied, .restricted:
                state = .denied
                finish(nil)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
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
        MainActor.assumeIsolated {
            state = .failed(error.localizedDescription)
            finish(nil)
        }
    }
}
