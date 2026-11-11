import SwiftUI
import AppKit
import Charts

/// Lupa de espaço: navega pelas pastas mostrando o que ocupa mais.
struct SpaceLensView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.scanned.contains(.lens) {
            if state.lensSource == 1 {
                VStack(alignment: .leading, spacing: 16) {
                    TopBar(section: .lens) { LensSourceSwitch() }
                    Text("O que ocupa o seu Google Drive").font(.system(size: 26, weight: .light))
                    DriveLensView()
                }
            } else {
                SpaceLensResults()
            }
        } else {
            ModuleIntro(section: .lens) {
                withAnimation(.easeInOut(duration: 0.35)) { _ = state.scanned.insert(.lens) }
            }
        }
    }
}

private let lensPalette: [Color] = Theme.chart

struct SpaceLensResults: View {
    @EnvironmentObject var state: AppState
    @State private var path: [URL] = [FS.home]
    @State private var items: [FileItem] = []
    @State private var isDir: Set<URL> = []
    @State private var loading = false
    @State private var done = 0
    @State private var totalChildren = 0
    @State private var pending: FileItem?

    private var current: URL { path.last! }
    private var total: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Fatias do gráfico: 6 maiores + "Outros".
    private var slices: [(String, Int64, Color)] {
        let top = items.prefix(6)
        var s = top.enumerated().map { ($0.element.url.lastPathComponent, $0.element.size, lensPalette[$0.offset]) }
        let rest = items.dropFirst(6).reduce(0) { $0 + $1.size }
        if rest > 0 { s.append(("Outros (demais itens)", rest, Color(nsColor: .systemGray))) }
        return s.filter { $0.1 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TopBar(section: .lens) {
                LensSourceSwitch()
                Button { state.lensCache[current] = nil; Task { await load() } } label: {
                    Label("Medir de novo", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.8)).disabled(loading)
            }

            // Trilha de navegação
            HStack(spacing: 6) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, url in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.ink.opacity(0.74)) }
                    Button(i == 0 ? "Pasta pessoal" : url.lastPathComponent) {
                        path = Array(path.prefix(i + 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == path.count - 1 ? Color.ink : Color.ink.opacity(0.6))
                    .font(.system(size: i == path.count - 1 ? 26 : 15, weight: .semibold))
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 18) {
                // Mapa
                GlassCard(padding: 20) {
                    VStack(spacing: 18) {
                        ZStack {
                            Chart(Array(slices.enumerated()), id: \.offset) { _, s in
                                SectorMark(angle: .value("Tamanho", s.1), innerRadius: .ratio(0.62), angularInset: 1.5)
                                    .cornerRadius(5)
                                    .foregroundStyle(s.2)
                            }
                            .chartLegend(.hidden)
                            .animation(.easeInOut(duration: 0.4), value: items.count)
                            VStack(spacing: 2) {
                                Text(FS.fmt(total)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                                Text(loading ? "medindo \(done)/\(totalChildren)" : "nesta pasta")
                                    .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                            }
                        }
                        .frame(height: 250)
                        VStack(spacing: 8) {
                            ForEach(Array(slices.enumerated()), id: \.offset) { _, s in
                                HStack {
                                    Circle().fill(s.2).frame(width: 9, height: 9)
                                    Text(s.0).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(FS.fmt(s.1)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: 320)

                // Lista
                GlassCard(padding: 12) {
                    if items.isEmpty && loading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Somando o tamanho de cada pasta… a pasta pessoal pode levar um minuto.")
                                .foregroundStyle(Color.ink.opacity(0.76))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if items.isEmpty {
                        Text("Pasta vazia ou sem permissão de leitura.").foregroundStyle(Color.ink.opacity(0.76))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in row(item, i) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: current) { await load() }
        .confirmationDialog("Mover \(pending?.url.lastPathComponent ?? "") para a Lixeira?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Mover para a Lixeira", role: .destructive) {
                guard let p = pending else { return }
                Task {
                    let r = await state.measured("Lupa: \(p.url.lastPathComponent)") {
                        await Task.detached { FS.remove([p], permanently: false) }.value
                    }
                    if !r.failedPaths.contains(p.url.path) { items.removeAll { $0 == p }; state.lensCache[current] = items }
                }
            }
        } message: {
            if let p = pending, isCloud(p.url) {
                Text("⚠️ Esta pasta sincroniza com a nuvem: apagar aqui apaga lá também. Para só liberar espaço, use \"Remover download\" no Finder.")
            } else {
                Text("Confira se não é mídia de um projeto ativo. Dá para recuperar pela Lixeira.")
            }
        }
    }

    private func row(_ item: FileItem, _ index: Int) -> some View {
        let dir = isDir.contains(item.url)
        let frac = total > 0 ? Double(item.size) / Double(total) : 0
        let color = index < 6 ? lensPalette[index] : Color(nsColor: .systemGray)
        return HStack(spacing: 12) {
            Image(nsImage: IconCache.icon( item.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).lineLimit(1)
                    if isCloud(item.url) {
                        Image(systemName: "icloud").font(.caption).foregroundStyle(Theme.teal).help("Sincroniza com a nuvem")
                    }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.ink.opacity(0.1))
                        Capsule().fill(color).frame(width: max(3, g.size.width * frac))
                    }
                }
                .frame(height: 5)
            }
            Text(FS.fmt(item.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text("\(Int(frac * 100))%").font(.caption).monospacedDigit().foregroundStyle(Color.ink.opacity(0.74)).frame(width: 36, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.76)).help("Mostrar no Finder")
            Button { pending = item } label: { Image(systemName: "trash") }
                .disabled(isProtected(item.url))
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.76)).help("Mover para a Lixeira")
            Image(systemName: "chevron.right").foregroundStyle(dir ? Color.ink.opacity(0.6) : Color.clear)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ink.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { if dir { path.append(item.url) } }
    }

    /// Pastas que o app nunca oferece para apagar.
    private func isProtected(_ url: URL) -> Bool {
        let p = url.path, h = FS.home.path
        let blocked = [h + "/Library", h + "/Applications", h + "/Library/CloudStorage", h + "/Library/Mobile Documents",
                       h + "/Documents", h + "/Desktop", h + "/Downloads", h + "/Movies", h + "/Music", h + "/Pictures", h + "/Public"]
        return blocked.contains(p) || p.hasPrefix(h + "/Library/") || CloudEngine.isCloud(url)
    }

    private func isCloud(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/Library/CloudStorage") || p.contains("/Library/Mobile Documents") || p.contains("Google Drive")
    }

    private func load() async {
        let dir = current
        if let cached = state.lensCache[dir] { items = cached; refreshDirFlags(); loading = false; return }
        loading = true
        defer { if current == dir { loading = false } }
        items = []
        // lista os filhos e descobre quem é pasta fora da thread principal
        let listing: [(URL, Bool)] = await Task.detached {
            let keepHidden: Set<String> = [".cache", ".npm", ".Trash", ".ollama", ".lmstudio"]
            return FS.children(dir)
                .filter { !$0.lastPathComponent.hasPrefix(".") || keepHidden.contains($0.lastPathComponent) }
                .map { u in
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return (u, v?.isDirectory == true && v?.isPackage != true)
                }
        }.value
        guard !Task.isCancelled, current == dir else { return }
        isDir = Set(listing.filter(\.1).map(\.0))
        totalChildren = listing.count
        done = 0
        var batch: [FileItem] = []
        for (child, _) in listing {
            let size = await Task.detached { FS.size(of: child) }.value
            guard !Task.isCancelled, current == dir else { return }
            batch.append(FileItem(url: child, size: size))
            done += 1
            if batch.count >= 4 || done == listing.count {   // atualiza a tela em pequenos lotes
                items = (items + batch).sorted { $0.size > $1.size }
                batch = []
            }
        }
        state.lensCache[dir] = items
    }

    private func refreshDirFlags() {
        isDir = Set(items.filter {
            var d: ObjCBool = false
            return FS.fm.fileExists(atPath: $0.url.path, isDirectory: &d) && d.boolValue && $0.url.pathExtension != "app"
        }.map(\.url))
    }
}

/// Chave "Este Mac / Google Drive" da Lupa.
struct LensSourceSwitch: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 4) {
            option("Este Mac", "laptopcomputer", 0)
            option("Google Drive", "icloud.fill", 1)
        }
        .padding(3)
        .background(Capsule().fill(Color.ink.opacity(0.07)))
        .padding(.trailing, 8)
    }
    private func option(_ title: String, _ icon: String, _ i: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { state.lensSource = i } } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(state.lensSource == i ? Color.ink : Color.clear))
                .foregroundStyle(state.lensSource == i ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }
}
