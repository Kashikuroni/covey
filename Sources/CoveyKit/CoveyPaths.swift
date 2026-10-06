import Foundation

/// Единственное место, где решается, где лежит собственное состояние Covey
/// (сокет демона, registry.json, state.json, config.json, usage.json,
/// reviews, traces).
///
/// Прод — `~/.covey`. `COVEY_HOME` переносит всё дерево целиком: дев-инстанс
/// с собственным демоном и сессиями не задевает боевой. GUI передаёт
/// переменную спавнимому coveyd (окружение наследуется), поэтому достаточно
/// выставить её при запуске приложения. Внешние данные агентов (`~/.claude`,
/// `~/.codex`, keychain) всегда остаются на настоящем home — изолированный
/// инстанс работает с настоящими логинами.
public enum CoveyPaths {
    public static let overrideKey = "COVEY_HOME"

    /// Чистое разрешение корня — тестируемо без подмены процесса.
    /// `COVEY_HOME` заменяет home-каталог; `.covey` дописывается к нему.
    public static func resolve(home: String, env: [String: String]) -> String {
        if let root = env[overrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return (root as NSString).expandingTildeInPath + "/.covey"
        }
        return home + "/.covey"
    }

    /// Корень состояния текущего процесса.
    public static var root: String {
        resolve(home: NSHomeDirectory(),
                env: ProcessInfo.processInfo.environment)
    }

    /// Полный путь к `component` внутри корня состояния.
    public static func path(_ component: String) -> String {
        root + "/" + component
    }

    /// Сокет демона.
    public static var socketPath: String { path("coveyd.sock") }
}
