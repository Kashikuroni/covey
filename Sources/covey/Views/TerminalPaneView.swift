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
            if (model.activeView?.isSplit ?? false) || model.activeView?.terminal != nil {
                splitBody
            } else if let name = model.selected {
                VStack(spacing: 0) {
                    paneHeader("Agent", zone: .agent, name: name)
                    pane(name)
                }
                .panelCard(tk, surface: tk.termBg)
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
                companionRatio: model.activeView?.agentAreaRatio ?? 0.6,
                size: geo.size, gutter: Tokens.gutter)
            ZStack(alignment: .topLeading) {
                ForEach(leaves(frames)) { leaf in
                    paneStack(leaf.name, zone: .agent, label: "Agent")
                        .frame(width: leaf.frame.width, height: leaf.frame.height)
                        .offset(x: leaf.frame.minX, y: leaf.frame.minY)
                }
                // Шелл-колонка пережила закрытие своего агента: agent-область
                // не должна оставаться пустой.
                if frames.leaves.isEmpty, let area = frames.agentArea {
                    placeholder(model.selectedProjectRoot)
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                }
                if let shell = model.activeView?.terminal?.shellSession, let frame = frames.companion {
                    paneStack(shell, zone: .terminalSplit, label: "Terminal")
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                ForEach(frames.dividers.indices, id: \.self) { i in
                    divider(for: frames.dividers[i])
                }
                if model.activeView?.terminal != nil, let area = frames.agentArea,
                   let col = frames.companion {
                    columnDivider(areaWidth: area.width, colMinX: col.minX,
                                  height: geo.size.height)
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

    /// Делята узлов дерева: ручка в центре узла вдоль его оси.
    private func divider(for d: PanelLayout.SplitDivider) -> some View {
        let vertical = d.axis == .vertical
        let handle = CGRect(
            x: d.bounds.midX - (vertical ? Tokens.gutter / 2 : 0),
            y: d.bounds.midY - (vertical ? 0 : Tokens.gutter / 2),
            width: vertical ? Tokens.gutter : d.bounds.width,
            height: vertical ? d.bounds.height : Tokens.gutter)
        return Rectangle()
            .fill(Color.clear)
            .frame(width: handle.width, height: handle.height)
            .offset(x: handle.minX, y: handle.minY)
            .contentShape(Rectangle())
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

    /// Делята между agent-областью и шелл-колонкой.
    private func columnDivider(areaWidth: CGFloat, colMinX: CGFloat,
                               height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Tokens.gutter, height: height)
            .offset(x: areaWidth, y: 0)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(Self.splitSpace))
                    .onChanged { value in
                        let usable = max(0, colMinX - Tokens.gutter)
                        guard usable > 0 else { return }
                        model.setCompanionRatio(value.location.x / usable)
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
    /// session name behind it tells two agent panes apart.
    private func paneHeader(_ label: String, zone: FocusZone, name: String) -> some View {
        let active = model.focus == .terminal && model.focusedPane == name
        let parts = paneHeaderParts(label: label, name: name)
        return HStack(spacing: 6) {
            zoneTitle(parts.zone, zone: zone, active: active, tk: tk)
            if let session = parts.session {
                Text(session)
                    .font(.system(size: 12))
                    .foregroundStyle(panelLabelColor(.paneSession, tk: tk))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, Tokens.paneHeaderTop)
        .padding(.bottom, Tokens.paneHeaderBottom)
        .contentShape(Rectangle())
        .onTapGesture { if !name.isEmpty { model.focusPane(name) } }
    }

    private func pane(_ name: String) -> some View {
        TerminalRepresentable(model: model, name: name)
            .id(name)   // fresh TerminalView per session (spec §5)
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 4))
            .onTapGesture { model.focusPane(name) }
    }
}
