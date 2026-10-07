import SwiftUI
import CoveyKit

struct TerminalPaneView: View {
    let model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    /// Named space for every split drag: frames from `PanelLayout.splitFrames`
    /// live here, so nested dividers share one coordinate space (спека:
    /// уникальная геометрия на узел без коллизий имён).
    static let splitSpace = "splitview"

    var body: some View {
        VStack(spacing: 0) {
            // Одна структурная позиция на agent-панель при любом составе View.
            // Отдельная ветка «одна панель без терминала» стоила remount при
            // каждом открытии/закрытии терминала, а на переключении сессии
            // умирающая ветка успевала смонтировать ВТОРУЮ панель новой сессии:
            // аренда resize и вывод-сток (оба «последний mount выигрывает»)
            // доставались обречённому view, а панель на экране оставалась
            // пустой до следующего remount.
            if model.selected != nil {
                splitBody
            } else if let root = model.selectedProjectRoot {
                placeholder(root)
            } else {
                placeholder(nil)
            }
        }
    }

    /// Рекурсивный рендер: один GeometryReader считает кадры всех листьев и
    /// делят (`PanelLayout.splitFrames`), ZStack раскладывает панели по кадрам.
    private var splitBody: some View {
        GeometryReader { geo in
            // Одиночная панель живёт вне дерева (инвариант: дерево ⇔ ≥2 листа),
            // поэтому `selected` идёт в геометрию отдельным листом.
            let frames = PanelLayout.splitFrames(
                tree: model.visibleSplitTree, soloAgent: model.selected,
                companionShell: model.activeView?.terminal?.shellSession,
                companionAxis: model.activeView?.terminal?.axis ?? .vertical,
                companionRatio: model.activeView?.agentAreaRatio ?? 0.6,
                size: geo.size, gutter: Tokens.gutter)
            ZStack(alignment: .topLeading) {
                ForEach(leaves(frames)) { leaf in
                    paneStack(leaf.name, zone: .agent, label: "Agent")
                        .placed(in: leaf.frame)
                }
                // Шелл-колонка пережила закрытие своего агента: agent-область
                // не должна оставаться пустой.
                if frames.leaves.isEmpty, let area = frames.agentArea {
                    placeholder(model.selectedProjectRoot)
                        .placed(in: area)
                }
                if let shell = model.activeView?.terminal?.shellSession, let frame = frames.companion {
                    paneStack(shell, zone: .terminalSplit, label: "Terminal")
                        .placed(in: frame)
                }
                ForEach(frames.dividers.indices, id: \.self) { i in
                    divider(for: frames.dividers[i])
                }
                if model.activeView?.terminal != nil, let area = frames.agentArea,
                   let col = frames.companion {
                    columnDivider(area: area, companion: col,
                                  axis: model.activeView?.terminal?.axis ?? .vertical)
                }
            }
        }
        .coordinateSpace(name: Self.splitSpace)
    }

    /// Swift не поддерживает key path к полям тьюплов — обёртка для ForEach.
    private struct SplitLeaf: Identifiable {
        let name: String
        let frame: CGRect
        var id: String { name }
    }

    private func leaves(_ frames: PanelLayout.SplitFrames) -> [SplitLeaf] {
        frames.leaves
            .map { SplitLeaf(name: $0.key, frame: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Панель = заголовок-вкладка + терминал, в карточке (как сегодня).
    private func paneStack(_ name: String, zone: FocusZone, label: String) -> some View {
        VStack(spacing: 0) {
            paneHeader(label, zone: zone, name: name)
            pane(name)
        }
        .panelCard(tk, surface: tk.termBg)
    }

    /// Делята узлов дерева: ручка стоит в шве между потомками (`handle`
    /// считает `PanelLayout` — по середине узла шов лежит только при 0.5).
    private func divider(for d: PanelLayout.SplitDivider) -> some View {
        let vertical = d.axis == .vertical
        return Rectangle()
            .fill(Color.clear)
            .frame(width: d.handle.width, height: d.handle.height)
            .contentShape(Rectangle())
            .position(x: d.handle.midX, y: d.handle.midY)
            .onHover { inside in
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(Self.splitSpace))
                    .onChanged { value in
                        // ratio = позиция курсора внутри узла по его оси;
                        // клампы (0.15–0.85 + пол) — в модели и PanelLayout.
                        let usable = (vertical ? d.bounds.width : d.bounds.height)
                            - Tokens.gutter
                        guard usable > 0 else { return }
                        let pos = vertical ? value.location.x - d.bounds.minX
                                           : value.location.y - d.bounds.minY
                        model.setSplitRatio(path: d.path, ratio: pos / usable)
                    }
            )
    }

    /// Делята между agent-областью и шелл-зоной: вертикальная колонка — шов
    /// по X (курсор ↔), горизонтальная полоса — шов по Y (курсор ↕).
    private func columnDivider(area: CGRect, companion: CGRect, axis: PaneAxis) -> some View {
        let vertical = axis == .vertical
        return Rectangle()
            .fill(Color.clear)
            .frame(width: vertical ? Tokens.gutter : area.width,
                   height: vertical ? area.height : Tokens.gutter)
            .contentShape(Rectangle())
            .position(x: vertical ? area.maxX + Tokens.gutter / 2 : area.midX,
                      y: vertical ? area.midY : area.maxY + Tokens.gutter / 2)
            .onHover { inside in
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(Self.splitSpace))
                    .onChanged { value in
                        let usable = max(0, (vertical ? companion.minX : companion.minY)
                                       - Tokens.gutter)
                        guard usable > 0 else { return }
                        let pos = vertical ? value.location.x : value.location.y
                        model.setCompanionRatio(pos / usable)
                    }
            )
    }

    private func placeholder(_ root: String?) -> some View {
        VStack(spacing: 0) {
            paneHeader("Agent", zone: .agent, name: "")
            Spacer()
            VStack(spacing: 6) {
                if let root {
                    Text(model.displayName(forDir: root))
                        .font(.title3).foregroundStyle(.secondary)
                    Text(collapseHome(root))
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                Text("N — new session")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .panelCard(tk, surface: tk.termBg)
    }

    /// Tiny per-pane tab: the focused pane's label lights up in accent, the
    /// line under it — «<проект> - <сессия>» — говорит, что именно за панель.
    private func paneHeader(_ label: String, zone: FocusZone, name: String) -> some View {
        let active = model.focus == .terminal && model.focusedPane == name
        let subject = paneHeaderSubject(project: projectName(ofSession: name),
                                        session: name,
                                        isShell: zone == .terminalSplit)
        return VStack(alignment: .leading, spacing: 2) {
            zoneTitle(label, zone: zone, active: active, tk: tk)
            if let subject {
                Text(subject)
                    .font(.system(size: 12))
                    .foregroundStyle(panelLabelColor(.paneSubject, tk: tk))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, Tokens.paneHeaderTop)
        .padding(.bottom, Tokens.paneHeaderBottom)
        .contentShape(Rectangle())
        .onTapGesture { if !name.isEmpty { model.focusPane(name) } }
    }

    /// Имя проекта сессии — как в сайдбаре (переименование проекта учитывается).
    private func projectName(ofSession name: String) -> String? {
        model.sessions.first { $0.name == name }
            .map { model.displayName(forDir: sessionRoot($0)) }
    }

    private func pane(_ name: String) -> some View {
        TerminalRepresentable(model: model, name: name, parked: model.windowMode != .sessions)
            .id(name)   // fresh TerminalView per session (spec §5)
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 4))
            .onTapGesture { model.focusPane(name) }
    }
}

/// Absolute placement inside the split container.
///
/// `.position` — не `.offset`: offset двигает ТОЛЬКО отрисовку, layout-кадр
/// вида остаётся на месте, а зона попадания (`contentShape`, `onHover`,
/// жесты) считается по layout-кадру. Делята из-за этого ловили мышь в левом
/// верхнем углу области, а не в шве, где нарисованы. Панели этого не
/// показывали: они AppKit-вью и берут события мимо hit-тестинга SwiftUI.
/// `.position` кладёт вид в раскладку по-настоящему, и зона совпадает с
/// картинкой. Побочно даёт контейнеру полный размер области: `.position`
/// забирает всё предложенное место.
extension View {
    /// Размер кадра и его место. Порядок обязателен: сначала размер, потом
    /// `position` — она забирает всё предложенное место, и вид без своего
    /// размера растянулся бы на всю область.
    func placed(in frame: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}
