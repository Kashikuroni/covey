import SwiftUI
import CoveyGit
import CoveyCodeGraph

extension EdgeRoute {
    typealias AnimatableData = AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
                                              AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>>

    /// Lets an arrow glide with its cards when the layout changes.
    var animatableData: AnimatableData {
        get {
            AnimatablePair(AnimatablePair(start.animatableData, control1.animatableData),
                           AnimatablePair(control2.animatableData, end.animatableData))
        }
        set {
            start.animatableData = newValue.first.first
            control1.animatableData = newValue.first.second
            control2.animatableData = newValue.second.first
            end.animatableData = newValue.second.second
        }
    }
}

struct EdgeCurve: Shape {
    var route: EdgeRoute

    var animatableData: EdgeRoute.AnimatableData {
        get { route.animatableData }
        set { route.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: route.start)
        path.addCurve(to: route.end, control1: route.control1, control2: route.control2)
        return path
    }
}

struct EdgeArrow: Shape {
    var route: EdgeRoute

    var animatableData: EdgeRoute.AnimatableData {
        get { route.animatableData }
        set { route.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(route.arrowHead())
        path.closeSubpath()
        return path
    }
}

extension EdgeStroke {
    func color(_ tk: Tokens) -> Color {
        switch self {
        case .kept: return tk.t3
        case .added: return tk.accent
        case .removed, .broken: return tk.err
        case .neighbour: return tk.t4
        }
    }

    var style: StrokeStyle { StrokeStyle(lineWidth: width, lineCap: .round, dash: dash) }
}

/// The arrows under the cards. A link whose end has no card (a neighbour
/// past the row's limit) is not drawn.
struct ReviewGraphEdges: View {
    let visibility: LinkVisibility
    let rects: [String: CGRect]
    let changed: Set<String>
    let tk: Tokens

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibility.links, id: \.key) { link in
                if let from = rects[link.from], let to = rects[link.to] {
                    let route = EdgeRoute.between(from, to)
                    let stroke = EdgeStroke.of(link, changed: changed)
                    let focused = visibility.isFocused(link)
                    Group {
                        EdgeCurve(route: route)
                            .stroke(stroke.color(tk), style: focused && stroke != .broken
                                    ? StrokeStyle(lineWidth: stroke.width + 0.6, lineCap: .round, dash: stroke.dash)
                                    : stroke.style)
                        EdgeArrow(route: route).fill(stroke.color(tk))
                    }
                    .opacity(visibility.dims(link) ? 0.4 : 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Over the cards: ⚠ on every broken link, and the names of focused links
/// (the full list in the tooltip).
struct ReviewGraphLabels: View {
    let visibility: LinkVisibility
    let rects: [String: CGRect]
    let tk: Tokens

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibility.links, id: \.key) { link in
                if let from = rects[link.from], let to = rects[link.to] {
                    let mid = EdgeRoute.between(from, to).midpoint
                    let broken = link.state == .broken
                    if broken {
                        Text("⚠")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tk.err)
                            .opacity(visibility.dims(link) ? 0.4 : 1)
                            .allowsHitTesting(false)
                            .position(mid)
                    }
                    if visibility.isFocused(link), !link.names.isEmpty {
                        Text(EdgeLabel.text(link.names))
                            .font(ReviewFont.mono(10.5))
                            .foregroundStyle(tk.t1)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(tk.bg.opacity(0.9), in: RoundedRectangle(cornerRadius: Tokens.rSm))
                            .help(EdgeLabel.tooltip(link.names))
                            .position(x: mid.x, y: mid.y + (broken ? 16 : 0))
                    }
                }
            }
        }
    }
}

/// File statuses, arrow styles and what a neighbour card looks like.
struct ReviewGraphLegend: View {
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(FileStatus.allCases, id: \.self) { status in
                    Text("■ \(status.label)").foregroundStyle(status.color(tk))
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(tk.t3, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 16, height: 10)
                    Text("unchanged")
                }
            }
            HStack(spacing: 14) {
                ForEach(EdgeStroke.allCases, id: \.self) { stroke in
                    HStack(spacing: 5) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 4))
                            path.addLine(to: CGPoint(x: 22, y: 4))
                        }
                        .stroke(stroke.color(tk), style: stroke.style)
                        .frame(width: 22, height: 8)
                        Text(stroke == .broken ? "broken ⚠" : stroke.label)
                    }
                }
            }
        }
        .font(ReviewFont.caption(10))
        .foregroundStyle(tk.t3)
        .allowsHitTesting(false)
    }
}

/// Top right of the canvas: "Updating links…", and why links are missing.
struct ReviewGraphStatus: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 10) {
            if model.graphUpdating {
                ProgressView().controlSize(.mini)
                Text("Updating links…").foregroundStyle(tk.t3)
            }
            if let notice = model.graphNotice {
                switch notice {
                case .incomplete:
                    Text(notice.text).foregroundStyle(tk.warn)
                case .unavailable:
                    Text(notice.text).foregroundStyle(tk.err).lineLimit(2)
                    ReviewButton(title: "Retry", tk: tk) { model.retryGraph() }
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// An unchanged file one link away from the selected one: muted, dashed,
/// with up to five usage lines. A user's lines are in the neighbour; a used
/// file's lines are in the selected file, where it is used.
struct ReviewNeighbourCard: View {
    static let shownSites = 5

    let path: String
    let sites: [UsageSite]
    let faded: Bool
    let tk: Tokens
    let openSite: (UsageSite) -> Void
    let openFile: () -> Void

    var body: some View {
        let dir = (path as NSString).deletingLastPathComponent
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if !dir.isEmpty { Text(dir + "/").foregroundStyle(tk.t4) }
                Text((path as NSString).lastPathComponent).foregroundStyle(tk.t2)
                Spacer(minLength: 6)
                Text("unchanged").font(ReviewFont.caption(9.5)).foregroundStyle(tk.t4)
            }
            .font(ReviewFont.mono(11.5))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(tk.bd2).frame(height: 1)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(sites.prefix(Self.shownSites), id: \.self) { site in
                    Button { openSite(site) } label: {
                        HStack(spacing: 8) {
                            Text("\(site.line)")
                                .foregroundStyle(tk.t4)
                                .frame(width: 34, alignment: .trailing)
                            Text(site.text).foregroundStyle(tk.t2)
                            Spacer(minLength: 0)
                        }
                        .font(ReviewFont.mono(10.5))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(site.path):\(site.line)")
                }
                if sites.count > Self.shownSites {
                    Text("\(sites.count - Self.shownSites) more")
                        .font(.system(size: 11))
                        .foregroundStyle(tk.t3)
                        .padding(.leading, 42)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                ReviewButton(title: "Open file", tk: tk, action: openFile)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(tk.surface)
        .overlay(RoundedRectangle(cornerRadius: Tokens.rSm)
            .stroke(tk.bd3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
        .opacity(faded ? 0.4 : 0.85)
    }
}
