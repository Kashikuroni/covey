import AppKit
import Observation

/// Главное окно приложения среди всех окон процесса: у рабочего окна есть
/// титульный стиль, а статус-барные и прочие служебные — панели (NSPanel)
/// либо окна без титула. canBecomeMain тут не критерий: вне запущенного
/// приложения (например, в тестах) он ложен даже для обычных окон.
/// nil — главного окна нет (активация всё равно выведет приложение вперёд).
@MainActor
func limitsActivationWindow(from windows: [NSWindow]) -> NSWindow? {
    windows.first { !$0.isKind(of: NSPanel.self) && $0.styleMask.contains(.titled) }
}

/// Действие левого клика по статус-айтему: активировать приложение, поднять
/// главное окно и открыть detailed limits overlay — тот же путь, что ⌘L
/// (`Show Limits Detail`). Вынесено из контроллера, чтобы тестировать без
/// настоящего системного айтема.
@MainActor
func openLimitsDetailFromStatusBar(model: AppModel) {
    NSApp.activate(ignoringOtherApps: true)
    if let window = limitsActivationWindow(from: NSApp.windows) {
        window.makeKeyAndOrderFront(nil)
    }
    model.perform(.showLimitsDetail)
}

/// Статус-айтем лимитов — замена ушедшему MenuBarExtra-поповеру. Тот же
/// атрибутированный заголовок (`menuBarLimitsAttributedTitle` →
/// `menuBarLimitsImage`); левый клик открывает detailed limits overlay в
/// главном окне вместо локального поповера. Видимостью управляет
/// переключатель «Show in macOS menu bar» (`model.menuBarLimitsEnabled`).
@MainActor
final class MenuBarLimitsStatusItem {
    private let item: NSStatusItem
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(didClick)
        item.button?.setAccessibilityLabel("Covey AI Usage Limits")
        sync()
        observe()
    }

    deinit {
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
        let forecast = model.glmForecast
        item.isVisible = model.menuBarLimitsEnabled
        guard model.menuBarLimitsEnabled else { return }
        item.button?.image = menuBarLimitsImage(menuBarLimitsAttributedTitle(
            usage: usage, codexUsage: codexUsage, glmQuota: glmQuota,
            glmEnabled: glmEnabled, forecast: forecast))
        item.button?.setAccessibilityValue(menuBarLimitsTitle(
            usage: usage, codexUsage: codexUsage, glmQuota: glmQuota,
            glmEnabled: glmEnabled, forecast: forecast))
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

    /// Левый клик: поднять приложение и открыть limits overlay (⌘L-путь).
    @objc private func didClick() {
        openLimitsDetailFromStatusBar(model: model)
    }
}
