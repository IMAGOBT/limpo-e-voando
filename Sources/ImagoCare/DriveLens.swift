import SwiftUI
import AppKit
import Charts

// MARK: - Motor: lê o Drive pela pasta do Mac, sem baixar nada

struct DriveReport: Sendable {
    var root: URL
    var total: Int64 = 0
    var fileCount = 0
    var downloaded: Int64 = 0
    var big: [FileItem] = []          // ≥ 100 MB
    var old: [FileItem] = []          // ≥ 50 MB e sem mudança há mais de 1 ano
    var dups: [DuplicateGroup] = []   // mesmo nome + mesmo tamanho (≥ 1 MB)

    // Árvore para navegar por pastas
    var dirSize: [String: Int64] = [:]
    var subdirs: [String: Set<String>] = [:]
    var files: [String: [FileItem]] = [:]

    /// Conteúdo de uma pasta (subpastas com tamanho somado + arquivos), do maior para o menor.
    func children(of path: String) -> [FileItem] {
        let dirs = (subdirs[path] ?? []).map { FileItem(url: URL(fileURLWithPath: $0), size: dirSize[$0] ?? 0) }
        return (dirs + (files[path] ?? [])).sorted { $0.size > $1.size }
    }

    func isDir(_ path: String) -> Bool { dirSize[path] != nil }
}

enum DriveEngine {
    static func scan(root: URL, progress: @escaping @Sendable (Int, Int64) -> Void) -> DriveReport {
        var r = DriveReport(root: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        var byKey: [String: [FileItem]] = [:]
        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        let rootPath = root.path
        var lastEmit = Date.distantPast
        r.dirSize[rootPath] = 0

        guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                       errorHandler: { _, _ in true }) else { return r }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            r.total += size
            r.fileCount += 1
            r.downloaded += Int64(v.totalFileAllocatedSize ?? 0)

            let item = FileItem(url: u, size: size, modified: v.contentModificationDate)
            // soma o tamanho em todas as pastas acima do arquivo
            var dir = u.deletingLastPathComponent().path
            r.files[dir, default: []].append(item)
            while dir.hasPrefix(rootPath) {
                r.dirSize[dir, default: 0] += size
                if dir == rootPath { break }
                let parent = (dir as NSString).deletingLastPathComponent
                r.subdirs[parent, default: []].insert(dir)
                dir = parent
            }

            if size >= 100 * 1024 * 1024 { r.big.append(item) }
            if size >= 50 * 1024 * 1024, let d = v.contentModificationDate, d < yearAgo { r.old.append(item) }
            if size >= 1024 * 1024 { byKey["\(u.lastPathComponent.lowercased())|\(size)", default: []].append(item) }

            if r.fileCount % 250 == 0, Date().timeIntervalSince(lastEmit) > 0.3 { lastEmit = Date(); progress(r.fileCount, r.total) }
        }

        r.big.sort { $0.size > $1.size }
        r.old.sort { $0.size > $1.size }
        r.dups = byKey.values.filter { $0.count > 1 }
            .map { files in
                let sorted = files.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                return DuplicateGroup(hash: sorted.map(\.url.path).joined(separator: "|"), files: sorted)
            }
            .sorted { $0.wasted > $1.wasted }
        progress(r.fileCount, r.total)
        return r
    }
}

extension AppState {
    var driveRoot: URL? {
        if let c = cachedDriveRoot { return c }
        let r = CloudEngine.destinations().first { $0.name == "Google Drive" }?.root
        cachedDriveRoot = .some(r)
        return r
    }

    func scanDrive() async {
        guard let root = driveRoot, !driveScanning else { return }
        driveScanning = true
        driveProgress = (0, 0)
        let report = await Task.detached {
            DriveEngine.scan(root: root) { count, bytes in
                Task { @MainActor in self.driveProgress = (count, bytes) }
            }
        }.value
        driveReport = report
        driveScanning = false
    }

    func trashDriveDups() async {
        guard let r = driveReport else { return }
        let items = r.dups.flatMap(\.files).filter { selected.contains($0.url) }
        isWorking = true
        let res = await Task.detached { FS.remove(items, permanently: false) }.value
        let removed = Set(items.filter { !res.failedPaths.contains($0.url.path) }.map(\.url))
        var updated = r
        updated.dups = r.dups.compactMap { g in
            let left = g.files.filter { !removed.contains($0.url) }
            return left.count > 1 ? DuplicateGroup(hash: g.hash, files: left) : nil
        }
        updated.big.removeAll { removed.contains($0.url) }
        updated.old.removeAll { removed.contains($0.url) }
        for item in items where removed.contains(item.url) {
            var dir = item.url.deletingLastPathComponent().path
            updated.files[dir]?.removeAll { $0.url == item.url }
            while dir.hasPrefix(r.root.path) {
                updated.dirSize[dir, default: 0] -= item.size
                if dir == r.root.path { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        updated.total -= res.freed
        driveReport = updated
        items.forEach { selected.remove($0.url) }
        isWorking = false
        toast = "\(FS.fmt(res.freed)) liberados no Google Drive · ficam 30 dias na Lixeira do Drive"
            + (res.failures.isEmpty ? "" : " · \(res.failures.count) não puderam ser movidos")
    }
}

// MARK: - Tela

private let drivePalette: [Color] = Theme.chart

struct DriveLensView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0
    @State private var path: [String] = []   // pilha de pastas abertas (vazia = raiz)
    @State private var confirmDups = false

    var body: some View {
        Group {
            if state.driveRoot == nil {
                EmptyState(icon: "icloud.slash", title: "Google Drive não encontrado",
                           text: "Instale o Google Drive para computador e entre na sua conta para analisar a nuvem.")
            } else if let r = state.driveReport, !state.driveScanning {
                report(r)
            } else {
                scanning
            }
        }
        .task { if state.driveReport == nil { await state.scanDrive() } }
        .confirmationDialog("Remover os duplicados marcados do Google Drive?", isPresented: $confirmDups) {
            Button("Mover para a Lixeira do Drive", role: .destructive) { Task { await state.trashDriveDups() } }
        } message: {
            Text("Eles saem do Drive (e de onde estiverem compartilhados) e ficam 30 dias na Lixeira do Google Drive, onde dá para recuperar. Confira antes se não são versões diferentes com o mesmo nome.")
        }
    }

    private var scanning: some View {
        VStack(spacing: 18) {
            Spacer()
            GlassHero(symbol: "icloud.fill", tint: Section.cloud.accent, radius: 999, size: 150)
            Text("Lendo o seu Google Drive…").font(.system(size: 22, weight: .semibold))
            Text("\(state.driveProgress.0) arquivos · \(FS.fmt(state.driveProgress.1)) na nuvem")
                .font(.system(size: 14)).monospacedDigit().foregroundStyle(Color.ink.opacity(0.75))
            Text("Nada é baixado: só leio nome, tamanho e data. Pastas que você nunca abriu podem demorar um pouco.")
                .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.74))
            ProgressView().controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pasta atual e filtros

    private func current(_ r: DriveReport) -> String { path.last ?? r.root.path }

    private func inside(_ url: URL, _ r: DriveReport) -> Bool {
        let c = current(r)
        return c == r.root.path || url.path.hasPrefix(c + "/")
    }

    private func big(_ r: DriveReport) -> [FileItem] { r.big.filter { inside($0.url, r) } }
    private func old(_ r: DriveReport) -> [FileItem] { r.old.filter { inside($0.url, r) } }
    private func dups(_ r: DriveReport) -> [DuplicateGroup] { r.dups.filter { $0.files.contains { inside($0.url, r) } } }

    private func slices(_ items: [FileItem]) -> [(String, Int64, Color)] {
        var s = items.prefix(6).enumerated().map { ($0.element.url.lastPathComponent, $0.element.size, drivePalette[$0.offset]) }
        let rest = items.dropFirst(6).reduce(0) { $0 + $1.size }
        if rest > 0 { s.append(("Outros (demais itens)", rest, Color(nsColor: .systemGray))) }
        return s.filter { $0.1 > 0 }
    }

    // MARK: Layout

    private func report(_ r: DriveReport) -> some View {
        let here = current(r)
        let items = r.children(of: here)
        let total = r.dirSize[here] ?? 0
        let dupList = dups(r)
        let dupWasted = dupList.reduce(0) { $0 + $1.wasted }

        return VStack(alignment: .leading, spacing: 12) {
            breadcrumb(r)
            HStack(alignment: .top, spacing: 18) {
                // Mapa da pasta atual
                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        ZStack {
                            Chart(Array(slices(items).enumerated()), id: \.offset) { _, s in
                                SectorMark(angle: .value("Tamanho", s.1), innerRadius: .ratio(0.62), angularInset: 1.5)
                                    .cornerRadius(5).foregroundStyle(s.2)
                            }
                            .chartLegend(.hidden)
                            .animation(.easeInOut(duration: 0.35), value: here)
                            VStack(spacing: 2) {
                                Text(FS.fmt(total)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                                Text(path.isEmpty ? "no Google Drive" : "nesta pasta")
                                    .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                            }
                        }
                        .frame(height: 210)
                        VStack(spacing: 7) {
                            ForEach(Array(slices(items).enumerated()), id: \.offset) { _, s in
                                HStack {
                                    Circle().fill(s.2).frame(width: 9, height: 9)
                                    Text(s.0).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(FS.fmt(s.1)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                }
                            }
                        }
                        Divider().overlay(Color.ink.opacity(0.15))
                        stat("Arquivos no Drive", "\(r.fileCount)")
                        stat("Baixados no Mac", FS.fmt(r.downloaded))
                        stat("Duplicados aqui", FS.fmt(dupWasted))
                        if r.downloaded > 50_000_000 {
                            Button { state.section = .cloud } label: {
                                Text("Liberar o que está baixado →").font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.blue)
                        }
                        Spacer(minLength: 0)
                        Button { path = []; Task { await state.scanDrive() } } label: {
                            Label("Ler de novo", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.76))
                    }
                }
                .frame(width: 310)

                // Listas
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        tabButton("Conteúdo", 0)
                        tabButton("Grandes · \(big(r).count)", 1)
                        tabButton("Duplicados · \(FS.fmt(dupWasted))", 2)
                        tabButton("Antigos · \(old(r).count)", 3)
                    }
                    .padding(4).background(Capsule().fill(Color.ink.opacity(0.07)))

                    GlassCard(padding: 12) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                switch tab {
                                case 0: contentRows(items, total: total, r: r)
                                case 1: fileRows(big(r), empty: "Nenhum arquivo acima de 100 MB aqui.")
                                case 2: dupRows(dupList)
                                default: fileRows(old(r), empty: "Nenhum arquivo grande parado há mais de 1 ano aqui.")
                                }
                            }
                        }
                        .id(here + "\(tab)")
                    }

                    if tab == 2 && !dupList.isEmpty {
                        let sel = state.selectedSize(dupList.flatMap(\.files))
                        ActionDock(section: .cloud, label: "Selecionado: \(FS.fmt(sel)) · nada vem marcado",
                                   button: "Remover", enabled: sel > 0) { confirmDups = true }
                    }
                }
            }
        }
    }

    private func breadcrumb(_ r: DriveReport) -> some View {
        HStack(spacing: 6) {
            if !path.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.2)) { _ = path.popLast() } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).background(Circle().fill(Color.ink.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
            crumb("Meu Drive", isLast: path.isEmpty) { path = [] }
            ForEach(Array(path.enumerated()), id: \.offset) { i, p in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.ink.opacity(0.74))
                crumb((p as NSString).lastPathComponent, isLast: i == path.count - 1) { path = Array(path.prefix(i + 1)) }
            }
            Spacer()
            if !path.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current(r))]) } label: {
                    Label("Abrir no Finder", systemImage: "folder").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.75))
            }
        }
        .frame(height: 30)
    }

    private func crumb(_ title: String, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { action() } } label: {
            Text(title).lineLimit(1)
                .font(.system(size: isLast ? 20 : 14, weight: .semibold))
                .foregroundStyle(isLast ? Color.ink : Color.ink.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func contentRows(_ items: [FileItem], total: Int64, r: DriveReport) -> some View {
        if items.isEmpty {
            Text("Pasta vazia.").foregroundStyle(Color.ink.opacity(0.76)).padding(30)
        }
        ForEach(Array(items.prefix(400).enumerated()), id: \.element.id) { i, f in
            let dir = r.isDir(f.url.path)
            let frac = total > 0 ? Double(f.size) / Double(total) : 0
            HStack(spacing: 12) {
                Image(nsImage: IconCache.icon( f.url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(f.url.lastPathComponent).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.ink.opacity(0.1))
                            Capsule().fill(i < 6 ? drivePalette[i] : Color(nsColor: .systemGray))
                                .frame(width: max(3, g.size.width * frac))
                        }
                    }
                    .frame(height: 5)
                }
                Text(FS.fmt(f.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                Text("\(Int(frac * 100))%").font(.caption).monospacedDigit().foregroundStyle(Color.ink.opacity(0.74)).frame(width: 36, alignment: .trailing)
                Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.76)).help("Mostrar no Finder")
                Image(systemName: "chevron.right").foregroundStyle(dir ? Color.ink.opacity(0.6) : Color.clear)
            }
            .padding(.vertical, 7).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if dir { withAnimation(.easeInOut(duration: 0.2)) { path.append(f.url.path) } }
            }
            Divider().overlay(Color.ink.opacity(0.06))
        }
        if items.count > 400 {
            Text("+ \(items.count - 400) itens menores").font(.caption).foregroundStyle(Color.ink.opacity(0.74)).padding(12)
        }
    }

    @ViewBuilder private func fileRows(_ items: [FileItem], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).foregroundStyle(Color.ink.opacity(0.76)).padding(30)
        } else {
            ForEach(items.prefix(300)) { item in
                ItemRow(item: item, selectable: false)
                Divider().overlay(Color.ink.opacity(0.06))
            }
        }
    }

    @ViewBuilder private func dupRows(_ groups: [DuplicateGroup]) -> some View {
        if groups.isEmpty {
            Text("Nenhum duplicado provável (mesmo nome e mesmo tamanho) aqui.").foregroundStyle(Color.ink.opacity(0.76)).padding(30)
        } else {
            ForEach(groups.prefix(300)) { g in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(g.files.count)× \(g.files[0].url.lastPathComponent)").font(.headline).lineLimit(1)
                        Spacer()
                        Text("\(FS.fmt(g.wasted)) repetidos").font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                    }
                    ForEach(Array(g.files.enumerated()), id: \.element.id) { i, f in
                        ItemRow(item: f, badge: i == 0 ? "MAIS ANTIGO" : nil)
                    }
                }
                .padding(.vertical, 8)
                Divider().overlay(Color.ink.opacity(0.1))
            }
        }
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { tab = i } } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(tab == i ? Color.ink : Color.clear))
                .foregroundStyle(tab == i ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }
}
