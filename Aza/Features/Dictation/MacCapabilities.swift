import Foundation

/// Что «тянет» этот Mac: по нему подбирается рекомендованный профиль
/// распознавания (§5.4 просит объяснить пользователю выбор, а не просто
/// перечислить три варианта).
struct MacCapabilities {

    let chip: String
    /// Оперативная память в гигабайтах.
    let memoryGB: Int
    /// Свободное место в гигабайтах — большая модель занимает ~1,5 ГБ.
    let freeDiskGB: Int

    static func current() -> MacCapabilities {
        MacCapabilities(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            freeDiskGB: freeDiskGigabytes()
        )
    }

    /// Рекомендация: сначала память (модель целиком живёт в ней), затем
    /// место на диске. Пороги консервативны — лучше предложить более
    /// лёгкую модель, чем подвесить машину.
    var recommendedProfile: DictationController.Profile {
        guard freeDiskGB >= 4, memoryGB >= 16 else {
            return memoryGB >= 8 && freeDiskGB >= 2 ? .balanced : .fast
        }
        return .accurate
    }

    /// Человеческое объяснение, почему рекомендуем именно это.
    var recommendationReason: String {
        switch recommendedProfile {
        case .accurate:
            "\(chip), \(memoryGB) ГБ памяти — хватит на самую точную модель"
        case .balanced:
            "\(chip), \(memoryGB) ГБ памяти — оптимален баланс"
        case .fast:
            freeDiskGB < 2
                ? "Мало места на диске (\(freeDiskGB) ГБ) — берите лёгкую модель"
                : "\(memoryGB) ГБ памяти — лучше лёгкая модель"
        }
    }

    /// Хватает ли ресурсов на конкретный профиль (для предупреждений).
    func canRun(_ profile: DictationController.Profile) -> Bool {
        switch profile {
        case .fast: freeDiskGB >= 1
        case .balanced: memoryGB >= 8 && freeDiskGB >= 2
        case .accurate: memoryGB >= 16 && freeDiskGB >= 4
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    private static func freeDiskGigabytes() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return 0 }
        return Int(bytes / 1_073_741_824)
    }
}
