import SwiftUI
import AppKit
import CoreServices

// MARK: - Modelos

struct CloudDest: Identifiable, Hashable, Sendable {
    var id: URL { root }
    let name: String
    /// Pasta raiz da nuvem (ex.: .../GoogleDrive-conta/Meu Drive)
    let root: URL
    /// Onde os arquivos do Mac ficam guardados dentro da nuvem.
    var archive: URL { root.appendingPathComponent("Arquivo do Mac") }
}

enum JobStatus: Equatable, Sendable {
    case moving, uploading, freeing, done, failed(String)
}

struct CloudJob: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let source: URL
    var dest: URL
    let size: Int64
    var status: JobStatus = .moving
}

// MARK: - Motor

enum CloudEngine {
    static let home = FS.home
    static let unusedDays = 60

    /// Nuvens configuradas no Mac (Google Drive primeiro).
    static func destinations() -> [CloudDest] {
        var out: [CloudDest] = []
        let storage = home.appendingPathComponent("Library/CloudStorage")
        for d in FS.children(storage) {
            let n = d.lastPathComponent
            // pastas com "(data)" no nome são sobras de contas reconectadas
            guard !n.contains("(") else { continue }
            if n.hasPrefix("GoogleDrive-") {
                for sub in ["Meu Drive", "My Drive"] {
                    let u = d.appendingPathComponent(sub)
                    if FS.fm.fileExists(atPath: u.path) { out.append(CloudDest(name: "Google Drive", root: u)) }
                }
            } else if n.hasPrefix("OneDrive") {
                out.append(CloudDest(name: "OneDrive", root: d))
            } else if n.hasPrefix("Dropbox") {
                out.append(CloudDest(name: "Dropbox", root: d))
            }
        }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FS.fm.fileExists(atPath: icloud.path) { out.append(CloudDest(name: "iCloud Drive", root: icloud)) }
        return out
    }

    static func isCloud(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return true }
        let p = url.path
        return p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
    }

    /// Última vez que o arquivo foi aberto (Spotlight), ou nil.
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func isUnused(_ item: FileItem) -> Bool {
        guard let d = item.modified else { return false }
        return Date().timeIntervalSince(d) > Double(unusedDays) * 86_400
    }

    /// Arquivos a partir de 100 MB fora da nuvem, com a data do último uso.
    static func suggestions(minSize: Int64 = 100 * 1024 * 1024) -> [FileItem] {
        let roots = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"].map { home.appendingPathComponent($0) }
        var out: [FileItem] = []
        for root in roots {
            FS.walkFiles(root) { url, size, modified in
                guard size >= minSize, !isCloud(url) else { return }
                out.append(FileItem(url: url, size: size, modified: lastUsed(url) ?? modified))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Arquivos que já estão salvos na nuvem mas também têm cópia baixada no Mac.
    static func localCopies(in dests: [CloudDest]) -> [FileItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .ubiquitousItemIsUploadedKey, .contentModificationDateKey]
        var out: [FileItem] = []
        for d in dests {
            guard let e = FS.fm.enumerator(at: d.root, includingPropertiesForKeys: keys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                           errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let local = Int64(v.totalFileAllocatedSize ?? 0)
                if local >= 1_000_000, v.ubiquitousItemIsUploaded == true {
                    out.append(FileItem(url: u, size: local, modified: v.contentModificationDate))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Caminho de destino que espelha a pasta de origem: ~/Movies/x.mp4 → Arquivo do Mac/Movies/x.mp4
    static func destination(for source: URL, in dest: CloudDest) -> URL {
        let rel = source.path.hasPrefix(home.path + "/")
            ? String(source.path.dropFirst(home.path.count + 1))
            : source.lastPathComponent
        var target = dest.archive.appendingPathComponent(rel)
        var i = 2
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while FS.fm.fileExists(atPath: target.path) {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            target = target.deletingLastPathComponent().appendingPathComponent(name)
            i += 1
        }
        return target
    }

    static func move(_ source: URL, to target: URL) -> String? {
        do {
            try FS.fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FS.fm.moveItem(at: source, to: target)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func files(in url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FS.fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [url] }
        var out: [URL] = []
        if let e = FS.fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(f)
            }
        }
        return out
    }

    /// done = tudo enviado; error = a nuvem recusou o envio.
    static func uploadState(_ url: URL) -> (done: Bool, error: String?) {
        guard FS.fm.fileExists(atPath: url.path) else { return (false, "Arquivo não encontrado") }
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]
        for f in files(in: url) {
            let fresh = URL(fileURLWithPath: f.path) // evita valores em cache
            guard let v = try? fresh.resourceValues(forKeys: keys) else { return (false, nil) }
            if let err = v.ubiquitousItemUploadingError { return (false, err.localizedDescription) }
            if v.ubiquitousItemIsUploaded != true { return (false, nil) }
        }
        return (true, nil)
    }

    /// Tira a cópia local (o arquivo continua na nuvem e baixa ao abrir).
    @discardableResult
    static func evict(_ url: URL) -> Int {
        var ok = 0
        for f in files(in: url) where (try? FS.fm.evictUbiquitousItem(at: f)) != nil { ok += 1 }
        return ok
    }
}

// MARK: - Estado: envio para a nuvem

extension AppState {
    var cloudLocalTotal: Int64 { cloudLocal.reduce(0) { $0 + $1.size } }
    var selectedCloud: Int64 { selectedSize(cloudCandidates) }
    var cloudActive: Bool { cloudJobs.contains { $0.status == .moving || $0.status == .uploading || $0.status == .freeing } }

    func sendToCloud(_ items: [FileItem]) async {
        guard let dest = cloudDest, !items.isEmpty else { return }
        // 1. move (instantâneo: mesmo disco). A partir daqui o app da nuvem começa a enviar.
        for item in items {
            let target = CloudEngine.destination(for: item.url, in: dest)
            var job = CloudJob(name: item.url.lastPathComponent, source: item.url, dest: target, size: item.size)
            let err = await Task.detached { CloudEngine.move(item.url, to: target) }.value
            job.status = err.map { .failed($0) } ?? .uploading
            cloudJobs.insert(job, at: 0)
            selected.remove(item.url)
            if err == nil { cloudCandidates.removeAll { $0.url == item.url } }
        }
        // 2. um único laço acompanha todos os envios (evita contar em dobro)
        guard !cloudPolling else { return }
        cloudPolling = true
        defer { cloudPolling = false }
        let deadline = Date().addingTimeInterval(6 * 3600)
        func setStatus(_ id: UUID, _ s: JobStatus) {
            if let i = cloudJobs.firstIndex(where: { $0.id == id }) { cloudJobs[i].status = s }
        }
        while cloudJobs.contains(where: { $0.status == .uploading }) {
            let waiting = cloudJobs.filter { $0.status == .uploading }
            for job in waiting {
                let state = await Task.detached { CloudEngine.uploadState(job.dest) }.value
                if let err = state.error {
                    setStatus(job.id, .failed("Envio não confirmado: \(err)"))
                } else if state.done {
                    setStatus(job.id, .freeing)
                    await measured("\(job.name) → nuvem", settle: 3) {
                        await Task.detached { CloudEngine.evict(job.dest) }.value
                        return CleanResult(count: 1, freed: job.size)
                    }
                    setStatus(job.id, .done)
                } else if Date() > deadline {
                    setStatus(job.id, .failed("O Drive não confirmou o envio — o arquivo está na pasta do Drive, nada foi apagado"))
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    /// Libera a cópia local de arquivos que já estão na nuvem.
    func freeLocalCopies(_ items: [FileItem]) async {
        isWorking = true
        await measured("Cópias locais da nuvem", settle: 3) {
            var freed: Int64 = 0, count = 0
            for item in items {
                let n = await Task.detached { CloudEngine.evict(item.url) }.value
                if n > 0 { freed += item.size; count += 1 }
            }
            return CleanResult(count: count, freed: freed)
        }
        cloudLocal.removeAll { items.contains($0) }
        items.forEach { selected.remove($0.url) }
        isWorking = false
    }

    func addToCloudList(_ urls: [URL]) async {
        for u in urls where !cloudCandidates.contains(where: { $0.url == u }) {
            if CloudEngine.isCloud(u) { toast = "\(u.lastPathComponent) já está na nuvem."; continue }
            let size = await Task.detached { FS.size(of: u) }.value
            cloudCandidates.insert(FileItem(url: u, size: size, modified: CloudEngine.lastUsed(u)), at: 0)
            selected.insert(u)
        }
    }
}

// MARK: - Tela

struct CloudView: View {
    @EnvironmentObject var state: AppState
    @State private var onlyUnused = true
    @State private var confirmSend = false
    @State private var confirmFree = false

    var body: some View {
        if state.scanned.contains(.cloud) { results } else { ModuleIntro(section: .cloud) }
    }

    private var list: [FileItem] {
        onlyUnused ? state.cloudCandidates.filter { CloudEngine.isUnused($0) || state.selected.contains($0.url) }
                   : state.cloudCandidates
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            TopBar(section: .cloud) {
                if state.cloudDests.count > 1 {
                    Picker("", selection: $state.cloudDest) {
                        ForEach(state.cloudDests) { Text($0.name).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu).frame(width: 170)
                }
            }

            if state.cloudDest == nil {
                EmptyState(icon: "icloud.slash", title: "Nenhuma nuvem configurada",
                           text: "Instale o Google Drive para computador (ou ative o iCloud Drive) e analise de novo.")
            } else {
                HStack(alignment: .lastTextBaseline) {
                    Text("Mande para a nuvem o que pesa").font(.system(size: 30, weight: .light))
                    Spacer()
                    Text("Destino: \(state.cloudDest!.name) › Arquivo do Mac")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink.opacity(0.76))
                }

                if state.cloudLocalTotal > 0 {
                    localBanner
                } else if state.cloudLocalChecking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Conferindo em segundo plano se há arquivos da nuvem ocupando o Mac…")
                            .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    }
                }
                if !state.cloudJobs.isEmpty { jobsPanel }

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        tab("Sem uso há \(CloudEngine.unusedDays)+ dias", true)
                        tab("Todos acima de 100 MB", false)
                    }
                    .padding(4).background(Capsule().fill(Color.ink.opacity(0.07)))
                    Spacer()
                    PillButton(title: "Adicionar arquivos…", icon: "plus", prominent: false) { pickFiles() }
                }

                GlassCard(padding: 12) {
                    if list.isEmpty {
                        Text(onlyUnused ? "Nenhum arquivo pesado parado há mais de \(CloudEngine.unusedDays) dias. Veja a outra aba ou adicione arquivos."
                                        : "Nenhum arquivo acima de 100 MB fora da nuvem.")
                            .foregroundStyle(Color.ink.opacity(0.76)).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(list) { item in
                                    ItemRow(item: item, badge: badge(item))
                                    Divider().overlay(Color.ink.opacity(0.08))
                                }
                            }
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in await state.addToCloudList([url]) } }
                        }
                    }
                    return true
                }

                ActionDock(section: .cloud,
                           label: "Selecionado: \(FS.fmt(state.selectedCloud)) · arraste arquivos para a lista",
                           button: "Enviar", enabled: state.selectedCloud > 0) { confirmSend = true }
            }
        }
        .confirmationDialog("Enviar \(FS.fmt(state.selectedCloud)) para o \(state.cloudDest?.name ?? "")?", isPresented: $confirmSend) {
            Button("Enviar para a nuvem") {
                let items = state.cloudCandidates.filter { state.selected.contains($0.url) }
                Task { await state.sendToCloud(items) }
            }
        } message: {
            Text("Os arquivos vão para \"Arquivo do Mac\" no \(state.cloudDest?.name ?? "Drive"), na mesma estrutura de pastas. O espaço só é liberado depois que o upload terminar — deixe o app aberto. Eles continuam no Finder com ícone de nuvem e baixam sozinhos quando você abrir. Mídias de projetos do Premiere vão precisar ser reconectadas.")
        }
        .confirmationDialog("Liberar \(FS.fmt(state.cloudLocalTotal)) do Mac?", isPresented: $confirmFree) {
            Button("Liberar espaço") { Task { await state.freeLocalCopies(state.cloudLocal) } }
        } message: {
            Text("Nada é apagado: os arquivos continuam na nuvem e baixam de novo quando você abrir.")
        }
    }

    private var localBanner: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 16) {
                GlassHero(symbol: "arrow.down.circle.dotted", tint: Section.cloud.accent, radius: 999, size: 54, animated: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(FS.fmt(state.cloudLocalTotal)) já estão na nuvem, mas também ocupam o Mac")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(state.cloudLocal.count) arquivos baixados. Dá para liberar sem apagar nada.")
                        .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76))
                }
                Spacer()
                PillButton(title: "Liberar espaço", enabled: !state.isWorking) { confirmFree = true }
            }
        }
    }

    private var jobsPanel: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Envios").font(.headline)
                    Spacer()
                    if state.cloudActive {
                        Text("Deixe o app aberto até terminar").font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                    } else {
                        Button("Limpar lista") { state.cloudJobs.removeAll() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                    }
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.cloudJobs) { job in jobRow(job) }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
    }

    private func jobRow(_ job: CloudJob) -> some View {
        let (icon, text, color): (String, String, Color) = {
            switch job.status {
            case .moving: return ("arrow.right.circle", "Movendo…", Color.ink)
            case .uploading: return ("icloud.and.arrow.up", "Enviando para a nuvem…", Section.cloud.accent)
            case .freeing: return ("arrow.down.circle.dotted", "Liberando espaço…", Section.cloud.accent)
            case .done: return ("checkmark.icloud.fill", "Na nuvem · espaço liberado", Theme.teal)
            case .failed(let e): return ("exclamationmark.icloud.fill", e, Theme.red)
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            Text(job.name).lineLimit(1)
            Spacer()
            if job.status == .uploading || job.status == .freeing { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(color).lineLimit(1)
            Text(FS.fmt(job.size)).font(.caption).monospacedDigit().foregroundStyle(Color.ink.opacity(0.74)).frame(width: 70, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([job.dest]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.74)).help("Mostrar no Finder")
        }
    }

    private func tab(_ title: String, _ unused: Bool) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { onlyUnused = unused } } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(onlyUnused == unused ? Color.ink : Color.clear))
                .foregroundStyle(onlyUnused == unused ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ item: FileItem) -> String? {
        guard let d = item.modified, CloudEngine.isUnused(item) else { return nil }
        let months = Int(Date().timeIntervalSince(d) / (30 * 86_400))
        return months >= 1 ? "SEM USO HÁ \(months) \(months == 1 ? "MÊS" : "MESES")" : "SEM USO"
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Adicionar"
        panel.message = "Escolha arquivos ou pastas para mandar para a nuvem"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await state.addToCloudList(urls) }
        }
    }
}
