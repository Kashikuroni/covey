import Foundation

/// Единственное место, где решается, куда пишутся логи приложения.
///
/// Прод — `~/Library/Logs/Covey`. Под тестами — изолированный каталог во
/// временной папке: прогон не должен дописывать фикстуры в журнал реального
/// приложения, иначе разбор бага по логу читает чужие события как свои.
/// `COVEY_LOG_DIR` перекрывает оба режима (отладочные прогоны, CI-артефакты).
enum LogPaths {
    static let overrideKey = "COVEY_LOG_DIR"

    /// Чистое разрешение каталога — вся логика режимов тестируема без
    /// подмены процесса.
    static func resolve(home: String, env: [String: String], testing: Bool) -> String {
        if let dir = env[overrideKey], !dir.isEmpty { return dir }
        guard testing else { return home + "/Library/Logs/Covey" }
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSTemporaryDirectory() + "covey-tests-\(pid)/Logs"
    }

    /// Тестовый прогон: XCTest загружен в этот процесс. Проверяется рантайм,
    /// а не флаг сборки, — тестовая цель линкует тот же модуль `covey`.
    static let isTesting: Bool = {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    /// Каталог логов текущего процесса; создаётся при первом обращении.
    static let directory: String = {
        let dir = resolve(home: NSHomeDirectory(),
                          env: ProcessInfo.processInfo.environment,
                          testing: isTesting)
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> String { directory + "/" + name }
}
