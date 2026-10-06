import AppKit
import Observation

/// Статус-айтем лимитов — пассивный индикатор: атрибутированный заголовок
/// (`menuBarLimitsAttributedTitle` → `menuBarLimitsImage`) без действия по
/// клику — детальный просмотр живёт в Forecast (⌘L), управление в
/// настройках. Видимостью управляет переключатель «Show in macOS menu bar»
/// (`model.menuBarLimitsEnabled`).
@MainActor
final class MenuBarLimitsStatusItem {
    private let item: NSStatusItem
    private let model: AppModel
    /// Заголовок показывает окно 5h/7d с миганием красного 7d — фаза должна
    /// двигаться и без свежих данных, поэтому дёргаем sync по таймеру.
    private var blinkTimer: Timer?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.setAccessibilityLabel("Covey AI Usage Limits")
        sync()
        observe()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    deinit {
        blinkTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Перерисовывает заголовок и показывает/прячет айтем по переключателю.
    /// Данные читаются в локали до рендера, чтобы трекинг наблюдения видел
    /// ровно эти свойства.
    func sync() {
        let usage = model.usage
        let codexUsage = model.codexUsage
        let glmQuota = model.glmQuota
        let glmEnabled = model.glmUsageEnabled
        let claudeEnabled = model.claudeUsageEnabled
        let codexEnabled = model.codexUsageEnabled
        let forecast = model.glmForecast
        item.isVisible = model.menuBarLimitsEnabled
        guard model.menuBarLimitsEnabled else { return }
        item.button?.image = menuBarLimitsImage(menuBarLimitsAttributedTitle(
            usage: usage, codexUsage: codexUsage, glmQuota: glmQuota,
            glmEnabled: glmEnabled, forecast: forecast,
            claudeEnabled: claudeEnabled, codexEnabled: codexEnabled))
        item.button?.setAccessibilityValue(menuBarLimitsTitle(
            usage: usage, codexUsage: codexUsage, glmQuota: glmQuota,
            glmEnabled: glmEnabled, forecast: forecast,
            claudeEnabled: claudeEnabled, codexEnabled: codexEnabled))
    }

    /// Подписка на @Observable-модель: трекинг одноразовый, любое изменение
    /// затронутых здесь свойств перезапускает sync() и саму подписку.
    private func observe() {
        withObservationTracking {
            // apply у withObservationTracking неизолированный; наблюдение
            // всегда запускается с главного потока, так что доступ к модели
            // легален именно под assumeIsolated — трекинг видит чтения внутри.
            MainActor.assumeIsolated {
                _ = model.menuBarLimitsEnabled
                _ = model.usage
                _ = model.codexUsage
                _ = model.glmQuota
                _ = model.glmUsageEnabled
                _ = model.claudeUsageEnabled
                _ = model.codexUsageEnabled
                _ = model.glmForecast
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observe()
            }
        }
    }

}
