// DiskMapView.swift - interactive disk space sunburst (the "what is eating my
// disk" pane). Scans a folder tree, draws up to 4 rings of proportional arcs,
// click a segment to zoom into it, click the center to go back up. The side
// list shows the focused folder's contents with reveal and trash actions.
// Deletion is Trash-only and confirmed, like everywhere else in MacPulse.

import SwiftUI

// MARK: - Tree model

final class DiskNode: Identifiable {
    let id: String            // path (aggregates get a synthetic suffix)
    let name: String
    let url: URL?
    let isDir: Bool
    let isAggregate: Bool     // "(smaller items)" rollup, not a real file
    var size: Int64
    var children: [DiskNode] = []
    weak var parent: DiskNode?

    init(id: String, name: String, url: URL?, isDir: Bool,
         isAggregate: Bool = false, size: Int64 = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.isDir = isDir
        self.isAggregate = isAggregate
        self.size = size
    }

    var pathString: String { url?.path ?? (parent?.pathString ?? "") }
}

/// Recursive scanner. Keeps at most `maxChildren` children per directory
/// (>= 1 MB each); the rest roll up into one "(smaller items)" node so the
/// tree stays small even on huge disks. Sizes are always exact - pruning
/// only affects what is drawn, not what is counted.
final class DiskScanner {
    let maxChildren = 40
    let minChildSize: Int64 = 1_048_576
    var dirCount = 0
    var onProgress: ((Int) -> Void)? = nil

    func scan(_ url: URL, parent: DiskNode?) -> DiskNode {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let node = DiskNode(id: url.path, name: name, url: url, isDir: true)
        node.parent = parent

        dirCount += 1
        if dirCount % 500 == 0 { onProgress?(dirCount) }

        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                .totalFileAllocatedSizeKey,
            ],
            options: []) else {
            return node   // unreadable: counts as 0, same as DaisyDisk's hidden space
        }

        var kids: [DiskNode] = []
        for child in children {
            guard let v = try? child.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                .totalFileAllocatedSizeKey,
            ]) else { continue }
            if v.isSymbolicLink == true { continue }   // never follow links

            if v.isDirectory == true && v.isPackage != true {
                let sub = scan(child, parent: node)
                if sub.size > 0 { kids.append(sub) }
            } else {
                // plain file, or a package (.app etc.) treated as one leaf
                let size: Int64 = v.isPackage == true
                    ? dirSize(child)
                    : Int64(v.totalFileAllocatedSize ?? 0)
                if size > 0 {
                    let leaf = DiskNode(id: child.path, name: child.lastPathComponent,
                                        url: child, isDir: false, size: size)
                    leaf.parent = node
                    kids.append(leaf)
                }
            }
        }

        node.size = kids.map { $0.size }.reduce(0, +)
        kids.sort { $0.size > $1.size }

        var kept: [DiskNode] = []
        var rolled: Int64 = 0
        for kid in kids {
            if kept.count < maxChildren && kid.size >= minChildSize {
                kept.append(kid)
            } else {
                rolled += kid.size
            }
        }
        if rolled > 0 {
            let agg = DiskNode(id: url.path + "/#smaller", name: "(smaller items)",
                               url: nil, isDir: false, isAggregate: true, size: rolled)
            agg.parent = node
            kept.append(agg)
        }
        node.children = kept
        return node
    }
}

// MARK: - Sunburst layout

struct ArcSeg: Identifiable {
    let node: DiskNode
    let ring: Int          // 1 = innermost ring around the hole
    let a0: Double         // degrees, 0 at 12 o'clock going clockwise
    let a1: Double
    var id: String { "\(node.id)#\(ring)" }
    var mid: Double { (a0 + a1) / 2 }
}

let sunburstRings = 4

func sunburstLayout(focus: DiskNode) -> [ArcSeg] {
    var segs: [ArcSeg] = []
    func place(_ node: DiskNode, ring: Int, a0: Double, a1: Double) {
        guard ring <= sunburstRings, node.size > 0 else { return }
        var angle = a0
        for child in node.children {
            let sweep = (a1 - a0) * Double(child.size) / Double(node.size)
            if sweep >= 0.5 {   // arcs under half a degree aren't clickable anyway
                segs.append(ArcSeg(node: child, ring: ring, a0: angle, a1: angle + sweep))
                if !child.children.isEmpty {
                    place(child, ring: ring + 1, a0: angle, a1: angle + sweep)
                }
            }
            angle += sweep
        }
    }
    place(focus, ring: 1, a0: 0, a1: 360)
    return segs
}

func segColor(_ seg: ArcSeg, hovered: Bool) -> Color {
    if seg.node.isAggregate {
        return Color.gray.opacity(hovered ? 0.55 : 0.35)
    }
    let hue = seg.mid / 360
    let sat = 0.62 - Double(seg.ring - 1) * 0.09
    let bri = (hovered ? 1.0 : 0.92) - Double(seg.ring - 1) * 0.05
    return Color(hue: hue, saturation: max(sat, 0.25), brightness: min(bri, 1.0))
}

// MARK: - View model

final class DiskMapModel: ObservableObject {
    @Published var root: DiskNode? = nil
    @Published var focus: DiskNode? = nil
    @Published var segments: [ArcSeg] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var status: String? = nil
    var neverScanned = true

    func scan(url: URL) {
        guard !scanning else { return }
        scanning = true
        neverScanned = false
        status = nil
        root = nil
        focus = nil
        segments = []
        progress = "Scanning \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let scanner = DiskScanner()
            scanner.onProgress = { n in
                DispatchQueue.main.async {
                    self.progress = "Scanning… \(n) folders"
                }
            }
            let tree = scanner.scan(url, parent: nil)
            DispatchQueue.main.async {
                self.root = tree
                self.scanning = false
                self.progress = ""
                self.refocus(tree)
            }
        }
    }

    func scanHome() { scan(url: FileManager.default.homeDirectoryForCurrentUser) }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to map"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url: url)
        }
    }

    func refocus(_ node: DiskNode) {
        focus = node
        segments = sunburstLayout(focus: node)
    }

    func zoomOut() {
        if let parent = focus?.parent { refocus(parent) }
    }

    var breadcrumbs: [DiskNode] {
        var chain: [DiskNode] = []
        var cur = focus
        while let n = cur { chain.append(n); cur = n.parent }
        return chain.reversed()
    }

    /// Move a node to the Trash and subtract its size up the tree - no rescan needed.
    func trash(_ node: DiskNode) {
        guard let url = node.url, !node.isAggregate else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            status = "Could not move \(node.name) to Trash: \(error.localizedDescription)"
            return
        }
        var up: DiskNode? = node.parent
        while let n = up { n.size -= node.size; up = n.parent }
        node.parent?.children.removeAll { $0.id == node.id }
        status = "Moved \(node.name) (\(fmtBytes(node.size))) to Trash"
        if let f = focus { refocus(f) }   // also republishes for the list
    }
}

// MARK: - Sunburst view

struct SunburstView: View {
    @ObservedObject var model: DiskMapModel
    @State private var hoveredID: String? = nil

    var hoveredSeg: ArcSeg? { model.segments.first { $0.id == hoveredID } }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let R = side / 2 - 10
            let r0 = R * 0.28
            let ringW = (R - r0) / CGFloat(sunburstRings)

            ZStack {
                Canvas { ctx, _ in
                    for seg in model.segments {
                        let inner = r0 + ringW * CGFloat(seg.ring - 1)
                        let outer = inner + ringW - 1.5
                        var p = Path()
                        p.addArc(center: center, radius: outer,
                                 startAngle: .degrees(seg.a0 - 90),
                                 endAngle: .degrees(seg.a1 - 90), clockwise: false)
                        p.addArc(center: center, radius: inner,
                                 startAngle: .degrees(seg.a1 - 90),
                                 endAngle: .degrees(seg.a0 - 90), clockwise: true)
                        p.closeSubpath()
                        ctx.fill(p, with: .color(segColor(seg, hovered: seg.id == hoveredID)))
                    }
                }

                // center hub: current folder, click to go up
                VStack(spacing: 2) {
                    if let f = model.focus {
                        Text(f.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: r0 * 1.6)
                        Text(fmtBytes(f.size))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if f.parent != nil {
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .position(center)

                // hover readout
                if let seg = hoveredSeg {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(seg.node.name).font(.system(size: 11, weight: .semibold))
                        Text(fmtBytes(seg.node.size) + pctText(seg))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    hoveredID = hitTest(pt, center: center, r0: r0, ringW: ringW)?.id
                case .ended:
                    hoveredID = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { g in
                        let pt = g.location
                        let d = hypot(pt.x - center.x, pt.y - center.y)
                        if d < r0 {
                            model.zoomOut()
                        } else if let seg = hitTest(pt, center: center, r0: r0, ringW: ringW),
                                  seg.node.isDir, !seg.node.children.isEmpty {
                            model.refocus(seg.node)
                        }
                    })
        }
    }

    func pctText(_ seg: ArcSeg) -> String {
        guard let f = model.focus, f.size > 0 else { return "" }
        return String(format: "  ·  %.1f%%", Double(seg.node.size) / Double(f.size) * 100)
    }

    func hitTest(_ pt: CGPoint, center: CGPoint, r0: CGFloat, ringW: CGFloat) -> ArcSeg? {
        let dx = pt.x - center.x, dy = pt.y - center.y
        let d = hypot(dx, dy)
        guard d >= r0 else { return nil }
        let ring = Int((d - r0) / ringW) + 1
        guard ring <= sunburstRings else { return nil }
        var ang = atan2(dy, dx) * 180 / .pi + 90   // 0 at 12 o'clock, clockwise
        if ang < 0 { ang += 360 }
        return model.segments.first { $0.ring == ring && ang >= $0.a0 && ang < $0.a1 }
    }
}

// MARK: - Pane

struct DiskMapView: View {
    @ObservedObject var model: DiskMapModel
    @State private var confirmTrash: DiskNode? = nil

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Button {
                    model.scanHome()
                } label: { Label("Scan Home", systemImage: "house") }
                    .disabled(model.scanning)
                Button("Choose Folder…") { model.pickFolder() }
                    .disabled(model.scanning)
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text(model.progress)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let root = model.root {
                    Text("\(root.name): \(fmtBytes(root.size))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            // breadcrumbs
            if model.focus != nil {
                HStack(spacing: 4) {
                    ForEach(model.breadcrumbs) { crumb in
                        Button(crumb.name) { model.refocus(crumb) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11,
                                          weight: crumb.id == model.focus?.id ? .semibold : .regular))
                            .foregroundStyle(crumb.id == model.focus?.id
                                             ? AnyShapeStyle(.primary)
                                             : AnyShapeStyle(.secondary))
                        if crumb.id != model.focus?.id {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text("click a segment to zoom in, click the center to go up")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }
            Divider()

            if model.focus == nil && !model.scanning {
                VStack(spacing: 10) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("See what is eating your disk")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Scan your home folder (or any folder) to get an interactive map. Bigger arc = more space.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button { model.scanHome() } label: {
                        Label("Scan Home Folder", systemImage: "house")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.scanning && model.focus == nil {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(model.progress)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    SunburstView(model: model)
                        .frame(minWidth: 360)
                        .padding(8)
                    Divider()
                    // contents of the focused folder
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.focus?.children ?? []) { child in
                                HStack(spacing: 8) {
                                    Image(systemName: child.isAggregate ? "ellipsis.circle"
                                          : child.isDir ? "folder.fill" : "doc")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(child.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1).truncationMode(.middle)
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.primary.opacity(0.07))
                                                Capsule().fill(Color.accentColor.opacity(0.7))
                                                    .frame(width: g.size.width * frac(child))
                                            }
                                        }
                                        .frame(height: 4)
                                    }
                                    Text(fmtBytes(child.size))
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .trailing)
                                    if !child.isAggregate {
                                        if child.isDir, !child.children.isEmpty {
                                            Button {
                                                model.refocus(child)
                                            } label: { Image(systemName: "plus.magnifyingglass") }
                                                .buttonStyle(.borderless)
                                                .help("Zoom into this folder")
                                        }
                                        Button {
                                            if let url = child.url {
                                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                            }
                                        } label: { Image(systemName: "magnifyingglass") }
                                            .buttonStyle(.borderless)
                                            .help("Reveal in Finder")
                                        Button {
                                            confirmTrash = child
                                        } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless)
                                            .help("Move to Trash")
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                    .frame(minWidth: 280, maxWidth: 340)
                }
            }

            if let status = model.status {
                Divider()
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .onAppear { if model.neverScanned { model.scanHome() } }
        .confirmationDialog(
            "Move \"\(confirmTrash?.name ?? "")\" (\(fmtBytes(confirmTrash?.size ?? 0))) to Trash?",
            isPresented: Binding(
                get: { confirmTrash != nil },
                set: { if !$0 { confirmTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let node = confirmTrash { model.trash(node) }
                confirmTrash = nil
            }
            Button("Cancel", role: .cancel) { confirmTrash = nil }
        } message: {
            Text("It goes to the Trash, recoverable until you empty it. The map updates without a rescan.")
        }
    }

    func frac(_ child: DiskNode) -> CGFloat {
        guard let f = model.focus, f.size > 0 else { return 0 }
        return CGFloat(child.size) / CGFloat(f.size)
    }
}
