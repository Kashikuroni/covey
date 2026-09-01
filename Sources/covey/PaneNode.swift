import Foundation
import CoveyKit

/// Axis of a `.split` node: vertical = side-by-side (новая панель справа),
/// horizontal = stacked (новая панель снизу).
enum PaneAxis: String, Codable, Equatable {
    case vertical, horizontal
}

/// Agent-pane grid of one window. Companion shells are NOT nodes — the
/// project shell lives in a separate right-hand column
/// (`AppModel.companionShell`). Инвариант: дерево не-nil ⇔ ≥2 листа.
indirect enum PaneNode: Equatable {
    case agent(session: String)
    case split(axis: PaneAxis, ratio: Double, first: PaneNode, second: PaneNode)

    /// Жёсткий лимит agent-панелей на окно (спека).
    static let maxLeaves = 8

    var leaves: [String] {
        switch self {
        case .agent(let s): return [s]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    var leafCount: Int { leaves.count }

    func contains(session name: String) -> Bool { leaves.contains(name) }

    /// Сплитит фокусный лист по оси; новая панель справа/снизу. nil — лист
    /// не найден или достигнут лимит. `nil`-дерево превращается в 2-листовое.
    static func splitting(_ tree: PaneNode?, focused: String,
                          axis: PaneAxis, newSession: String) -> PaneNode? {
        guard let tree else {
            return .split(axis: axis, ratio: 0.5,
                          first: .agent(session: focused),
                          second: .agent(session: newSession))
        }
        guard tree.leafCount < maxLeaves else { return nil }
        return tree.replacingNode(focused: focused) { leaf in
            .split(axis: axis, ratio: 0.5, first: leaf,
                   second: .agent(session: newSession))
        }
    }

    /// Переписывает лист `old` на `new` (rename и замена сессии в панели).
    func replacing(session old: String, with new: String) -> PaneNode {
        switch self {
        case .agent(let s):
            return s == old ? .agent(session: new) : self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio,
                          first: first.replacing(session: old, with: new),
                          second: second.replacing(session: old, with: new))
        }
    }

    /// Убирает лист и схлопывает узел; вторая ветка занимает место. Возвращает
    /// остаток (nil, когда остался один лист — инвариант корня) и
    /// панель-наследник фокуса (первый лист sibling-ветки). Убрать
    /// несуществующего или единственного листа — no-op.
    func removing(session name: String) -> (tree: PaneNode?, successor: String?) {
        guard leafCount > 1, contains(session: name) else { return (self, nil) }
        let (tree, successor) = removingNested(name)
        if tree.leafCount == 1 { return (nil, tree.leaves.first) }
        return (tree, successor)
    }

    /// Внутренняя рекурсия: вызывается только при ≥2 листьях и наличии `name`;
    /// всегда возвращает непустое поддерево. Схлопывание в nil — забота корня.
    private func removingNested(_ name: String) -> (PaneNode, String?) {
        switch self {
        case .split(let axis, let ratio, let first, let second):
            if first.contains(session: name) {
                if first.leafCount == 1 {
                    return (second, second.leaves.first)
                }
                let (shrunk, succ) = first.removingNested(name)
                return (.split(axis: axis, ratio: ratio, first: shrunk, second: second),
                        succ ?? second.leaves.first)
            }
            if second.leafCount == 1 {
                return (first, first.leaves.first)
            }
            let (shrunk, succ) = second.removingNested(name)
            return (.split(axis: axis, ratio: ratio, first: first, second: shrunk),
                    succ ?? first.leaves.first)
        case .agent:
            return (self, nil)
        }
    }

    private func replacingNode(focused: String,
                               _ transform: (PaneNode) -> PaneNode) -> PaneNode? {
        switch self {
        case .agent(let s):
            return s == focused ? transform(self) : nil
        case .split(let axis, let ratio, let first, let second):
            if let f = first.replacingNode(focused: focused, transform) {
                return .split(axis: axis, ratio: ratio, first: f, second: second)
            }
            if let s = second.replacingNode(focused: focused, transform) {
                return .split(axis: axis, ratio: ratio, first: first, second: s)
            }
            return nil
        }
    }

    /// Пишет ratio узла по index-path (пустой путь — этот узел); путь в лист
    /// или мимо дерева — no-op.
    static func setRatio(_ tree: PaneNode?, path: [Int], ratio: Double) -> PaneNode? {
        guard let tree else { return tree }
        guard case .split(let axis, let old, let first, let second) = tree else {
            return tree
        }
        guard let head = path.first else {
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }
        let tail = Array(path.dropFirst())
        if head == 0 {
            return .split(axis: axis, ratio: old,
                          first: setRatio(first, path: tail, ratio: ratio) ?? first,
                          second: second)
        }
        return .split(axis: axis, ratio: old, first: first,
                      second: setRatio(second, path: tail, ratio: ratio) ?? second)
    }
}

extension PaneNode {
    /// Round-trip через персист (spec «Миграция»: PersistedPaneNode в CoveyKit).
    init(persisted: PersistedPaneNode) {
        switch persisted {
        case .agent(let s): self = .agent(session: s)
        case .split(let axis, let ratio, let first, let second):
            self = .split(axis: PaneAxis(rawValue: axis) ?? .vertical, ratio: ratio,
                          first: PaneNode(persisted: first),
                          second: PaneNode(persisted: second))
        }
    }

    var persisted: PersistedPaneNode {
        switch self {
        case .agent(let s): return .agent(session: s)
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis.rawValue, ratio: ratio,
                          first: first.persisted, second: second.persisted)
        }
    }
}

