/// Аренда панели: какой из смонтированных на сессию view владеет ею сейчас.
struct TerminalViewLease: Equatable, Hashable, Sendable {
    let session: String
    fileprivate let generation: UInt64
}

/// Кто из панелей владеет сессией — её вывод и её размер идут только владельцу.
///
/// Владелец — последняя смонтированная панель: SwiftUI строит новый view до
/// сноса старого, поэтому «последняя» и есть та, что остаётся на экране.
/// Отличие от простого «последний mount выигрывает» — снос владельца не
/// обнуляет сессию, а передаёт её оставшейся панели. Переходное двойное
/// монтирование (SwiftUI успевает построить вторую панель той же сессии и
/// тут же снести её) иначе оставляет живую панель без вывода и без resize:
/// пустой экран агента до следующего remount.
struct TerminalPaneOwnership {
    /// Что стало с владением после сноса панели.
    enum Handover: Equatable {
        /// Снесли не владельца — владение не двигалось.
        case none
        /// Владелец ушёл, панелей на сессию не осталось.
        case vacant
        /// Владение перешло оставшейся панели.
        case passed(TerminalViewLease)
    }

    private var nextGeneration: UInt64 = 0
    /// Поколения панелей сессии в порядке монтирования; владелец — последнее.
    private var mounted: [String: [UInt64]] = [:]

    mutating func mount(session: String) -> TerminalViewLease {
        nextGeneration &+= 1
        mounted[session, default: []].append(nextGeneration)
        return TerminalViewLease(session: session, generation: nextGeneration)
    }

    func isCurrent(_ lease: TerminalViewLease) -> Bool {
        mounted[lease.session]?.last == lease.generation
    }

    @discardableResult
    mutating func unmount(_ lease: TerminalViewLease) -> Handover {
        guard var generations = mounted[lease.session],
              let index = generations.firstIndex(of: lease.generation) else { return .none }
        let wasOwner = generations.last == lease.generation
        generations.remove(at: index)
        mounted[lease.session] = generations.isEmpty ? nil : generations
        guard wasOwner else { return .none }
        guard let successor = generations.last else { return .vacant }
        return .passed(TerminalViewLease(session: lease.session, generation: successor))
    }
}
