import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Modelos

struct OrganizerConfig: Codable, Sendable {
    var folder: String = FS.home.appendingPathComponent("Downloads").path
    var byDate = false            // (antigo) mantido para compatibilidade
    var auto = false              // organizar sozinho todo dia
    var lastRun: Date?
    // Opções (opcionais para ler configurações antigas)
    var schemeRaw: Int?           // 0 tipo · 1 data + tipo · 2 só data · 3 extensão · 4 site de origem
    var dateLevelRaw: Int?        // 0 mês · 1 ano › mês · 2 dia
    var useCreationRaw: Bool?     // false = data em que chegou · true = data de criação
    var minAgeRaw: Int?           // só arquivos com mais de N dias (0 = todos)
    var renameRaw: Bool?          // renomear com a data na frente
    var foldersRaw: Bool?         // incluir pastas soltas
    var ignoredRaw: [String]?     // tipos que ficam onde estão

    var scheme: Int { get { schemeRaw ?? (byDate ? 1 : 0) } set { schemeRaw = newValue } }
    var dateLevel: Int { get { dateLevelRaw ?? 0 } set { dateLevelRaw = newValue } }
    var useCreation: Bool { get { useCreationRaw ?? false } set { useCreationRaw = newValue } }
    var minAge: Int { get { minAgeRaw ?? 0 } set { minAgeRaw = newValue } }
    var rename: Bool { get { renameRaw ?? false } set { renameRaw = newValue } }
    var folders: Bool { get { foldersRaw ?? false } set { foldersRaw = newValue } }
    var ignored: Set<String> { get { Set(ignoredRaw ?? []) } set { ignoredRaw = Array(newValue).sorted() } }
}

struct OrganizeMove: Codable, Hashable, Sendable {
    let from: String
    let to: String
}

struct OrganizePlanItem: Identifiable, Sendable {
    var id: String { src.path }
    let src: URL
    let dst: URL
    let size: Int64
    let group: String             // pasta de destino (para a prévia)
}

// MARK: - Motor

enum Organizer {
    /// Tipos e as pastas para onde vão.
    static let categories: [(name: String, icon: String)] = [
        ("Imagens", "photo"), ("Vídeos", "film"), ("Áudios", "waveform"), ("PDFs", "doc.richtext"),
        ("Documentos", "doc.text"), ("Planilhas", "tablecells"), ("Apresentações", "rectangle.on.rectangle"),
        ("Design", "paintbrush.pointed"), ("Compactados", "archivebox"), ("Instaladores", "shippingbox"),
        ("Código", "chevron.left.forwardslash.chevron.right"), ("Fontes", "textformat"), ("Outros", "questionmark.folder"),
    ]
    static var folderNames: Set<String> { Set(categories.map(\.name)) }

    static let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    static let designExt: Set<String> = ["psd", "psb", "ai", "eps", "fig", "sketch", "xd", "indd", "aep", "prproj", "drp", "blend", "c4d", "afdesign", "afphoto", "procreate"]
    static let installerExt: Set<String> = ["dmg", "pkg", "mpkg", "iso", "app", "exe", "msi"]
    static let archiveExt: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    static let codeExt: Set<String> = ["js", "ts", "tsx", "jsx", "py", "swift", "json", "html", "css", "sh", "rb", "go", "rs", "java", "kt", "php", "sql", "yml", "yaml", "md"]
    static let fontExt: Set<String> = ["ttf", "otf", "woff", "woff2"]

    static func category(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if designExt.contains(ext) { return "Design" }
        if installerExt.contains(ext) { return "Instaladores" }
        if archiveExt.contains(ext) { return "Compactados" }
        if fontExt.contains(ext) { return "Fontes" }
        if codeExt.contains(ext) { return "Código" }
        if ext == "pdf" { return "PDFs" }
        guard let t = UTType(filenameExtension: ext) else { return "Outros" }
        if t.conforms(to: .image) { return "Imagens" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "Vídeos" }
        if t.conforms(to: .audio) { return "Áudios" }
        if t.conforms(to: .spreadsheet) { return "Planilhas" }
        if t.conforms(to: .presentation) { return "Apresentações" }
        if t.conforms(to: .text) || t.conforms(to: .rtf) || ["doc", "docx", "pages", "odt", "txt", "rtf"].contains(ext) { return "Documentos" }
        return "Outros"
    }

    static func monthFolder(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "yyyy-MM LLLL"          // 2026-11 novembro
        return f.string(from: d)
    }

    static func isMonthFolder(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2} "#, options: .regularExpression) != nil
    }

    static func dateFolders(_ d: Date, level: Int) -> [String] {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        switch level {
        case 1: f.dateFormat = "yyyy"; let y = f.string(from: d); f.dateFormat = "MM LLLL"; return [y, f.string(from: d)]
        case 2: f.dateFormat = "yyyy-MM-dd"; return [f.string(from: d)]
        default: return [monthFolder(d)]
        }
    }

    /// Site de onde o arquivo foi baixado (o macOS guarda isso nos metadados do download).
    static func sourceSite(_ url: URL) -> String {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let froms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return "Origem desconhecida" }
        for s in froms {
            guard let host = URL(string: s)?.host?.lowercased() else { continue }
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let known: [(String, String)] = [("whatsapp", "WhatsApp"), ("drive.google", "Google Drive"), ("docs.google", "Google Docs"),
                                             ("mail.google", "Gmail"), ("googleusercontent", "Google"), ("instagram", "Instagram"),
                                             ("canva", "Canva"), ("figma", "Figma"), ("dropbox", "Dropbox"), ("wetransfer", "WeTransfer"),
                                             ("higgsfield", "Higgsfield"), ("openai", "ChatGPT"), ("chatgpt", "ChatGPT"), ("claude", "Claude"),
                                             ("freepik", "Freepik"), ("adobe", "Adobe"), ("apple", "Apple"), ("github", "GitHub")]
            if let k = known.first(where: { h.contains($0.0) }) { return k.1 }
            return h
        }
        return "Origem desconhecida"
    }

    /// Pastas que o próprio organizador cria (nunca são movidas de novo).
    static let knownSources: Set<String> = ["WhatsApp", "Google Drive", "Google Docs", "Gmail", "Google", "Instagram", "Canva", "Figma",
                                            "Dropbox", "WeTransfer", "Higgsfield", "ChatGPT", "Claude", "Freepik", "Adobe", "Apple", "GitHub",
                                            "Origem desconhecida", "Pastas", "Sem extensão"]
    static func isOrganizerFolder(_ n: String) -> Bool {
        if folderNames.contains(n) || knownSources.contains(n) || isMonthFolder(n) { return true }
        if n.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?$"#, options: .regularExpression) != nil { return true }   // 2026, 2026-11, 2026-11-10
        if n.count <= 6, n == n.uppercased(), n.rangeOfCharacter(from: .letters) != nil { return true }      // PDF, PNG, MP4…
        if n.contains("."), !n.contains(" ") { return true }                                                   // sites (ex.: wa.me)
        return false
    }

    /// Plano com as opções escolhidas. Só mexe no primeiro nível da pasta; ocultos, downloads em andamento
    /// e itens mexidos nos últimos 10 minutos ficam onde estão.
    static func plan(folder: URL, cfg: OrganizerConfig) -> [OrganizePlanItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                         .addedToDirectoryDateKey, .creationDateKey]
        let recent = Date().addingTimeInterval(-600)
        let oldLimit = cfg.minAge > 0 ? Date().addingTimeInterval(-Double(cfg.minAge) * 86_400) : nil
        let dfName = DateFormatter(); dfName.locale = Locale(identifier: "en_US_POSIX"); dfName.dateFormat = "yyyy-MM-dd"
        var out: [OrganizePlanItem] = []
        var taken = Set<String>()
        for u in FS.children(folder) {
            let n = u.lastPathComponent
            if n.hasPrefix(".") || partial.contains(u.pathExtension.lowercased()) { continue }
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            let isPackage = v.isPackage == true
            let isFolder = v.isDirectory == true && !isPackage
            if isFolder {
                // nunca move as pastas que o próprio organizador cria
                guard cfg.folders, !isOrganizerFolder(n) else { continue }
            } else if !(v.isRegularFile == true || isPackage) { continue }
            if let m = v.contentModificationDate, m > recent { continue }
            let date = (cfg.useCreation ? v.creationDate : (v.addedToDirectoryDate ?? v.creationDate)) ?? v.contentModificationDate ?? Date()
            if let oldLimit, date > oldLimit { continue }

            let cat = isFolder ? "Pastas" : category(for: u)
            if cfg.ignored.contains(cat) { continue }
            var parts: [String]
            switch cfg.scheme {
            case 1: parts = dateFolders(date, level: cfg.dateLevel) + [cat]
            case 2: parts = dateFolders(date, level: cfg.dateLevel)
            case 3: parts = [isFolder ? "Pastas" : (u.pathExtension.isEmpty ? "Sem extensão" : u.pathExtension.uppercased())]
            case 4: parts = [isFolder ? "Pastas" : sourceSite(u)]
            default: parts = [cat]
            }
            var dir = folder
            for p in parts { dir = dir.appendingPathComponent(p) }

            var name = n
            if cfg.rename && !isFolder {
                let prefix = dfName.string(from: date)
                if !n.hasPrefix(prefix) { name = "\(prefix) \(n)" }
            }
            var dst = dir.appendingPathComponent(name)
            var i = 2
            while FS.fm.fileExists(atPath: dst.path) || taken.contains(dst.path) {
                let b = (name as NSString).deletingPathExtension, e = (name as NSString).pathExtension
                dst = dir.appendingPathComponent(e.isEmpty ? "\(b) \(i)" : "\(b) \(i).\(e)")
                i += 1
            }
            taken.insert(dst.path)
            let size = (isPackage || isFolder) ? FS.size(of: u) : Int64(v.fileSize ?? 0)
            out.append(OrganizePlanItem(src: u, dst: dst, size: size, group: parts.joined(separator: "/")))
        }
        return out
    }

    /// Compatibilidade com chamadas antigas.
    static func plan(folder: URL, byDate: Bool) -> [OrganizePlanItem] {
        var c = OrganizerConfig(); c.scheme = byDate ? 1 : 0
        return plan(folder: folder, cfg: c)
    }

    /// Move de verdade. Retorna os movimentos feitos (para poder desfazer).
    static func apply(_ items: [OrganizePlanItem]) -> (moves: [OrganizeMove], failed: Int) {
        var moves: [OrganizeMove] = []
        var failed = 0
        for it in items {
            do {
                try FS.fm.createDirectory(at: it.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !FS.fm.fileExists(atPath: it.dst.path) else { failed += 1; continue }   // nunca sobrescreve
                try FS.fm.moveItem(at: it.src, to: it.dst)
                moves.append(OrganizeMove(from: it.src.path, to: it.dst.path))
            } catch { failed += 1 }
        }
        return (moves, failed)
    }

    /// Desfaz: devolve cada arquivo ao lugar original (se o lugar estiver livre) e remove pastas que ficaram vazias.
    static func undo(_ moves: [OrganizeMove]) -> (restored: Int, failed: Int) {
        var ok = 0, failed = 0
        var dirs = Set<String>()
        let created = Set(moves.map { ($0.to as NSString).deletingLastPathComponent })
        for m in moves.reversed() {
            guard FS.fm.fileExists(atPath: m.to), !FS.fm.fileExists(atPath: m.from) else { failed += 1; continue }
            do {
                try FS.fm.moveItem(atPath: m.to, toPath: m.from)
                ok += 1
                var d = (m.to as NSString).deletingLastPathComponent
                for _ in 0..<3 { dirs.insert(d); d = (d as NSString).deletingLastPathComponent }
            } catch { failed += 1 }
        }
        // apaga só pastas de organização que ficaram vazias (nunca pastas com conteúdo)
        for d in dirs.sorted(by: { $0.count > $1.count }) {
            let name = (d as NSString).lastPathComponent
            let isDateLike = name.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?( .+)?$"#, options: .regularExpression) != nil
            guard folderNames.contains(name) || isMonthFolder(name) || isDateLike || name == "Pastas" || name == name.uppercased() || created.contains(d) else { continue }
            if let c = try? FS.fm.contentsOfDirectory(atPath: d), c.filter({ $0 != ".DS_Store" }).isEmpty {
                try? FS.fm.removeItem(atPath: d)
            }
        }
        return (ok, failed)
    }
}

// MARK: - Estado

extension AppState {
    static let organizerKey = "organizer.config.v1"
    static let organizerUndoKey = "organizer.undo.v1"

    static func loadOrganizer() -> OrganizerConfig {
        (UserDefaults.standard.data(forKey: organizerKey)).flatMap { try? JSONDecoder().decode(OrganizerConfig.self, from: $0) } ?? OrganizerConfig()
    }
    static func loadOrganizerUndo() -> [OrganizeMove] {
        (UserDefaults.standard.data(forKey: organizerUndoKey)).flatMap { try? JSONDecoder().decode([OrganizeMove].self, from: $0) } ?? []
    }

    func editOrganizer(_ change: (inout OrganizerConfig) -> Void) {
        change(&organizer)
        if let d = try? JSONEncoder().encode(organizer) { UserDefaults.standard.set(d, forKey: Self.organizerKey) }
        organizerPlan = nil
    }

    /// Pastas permitidas: nada de sistema, home inteira, Biblioteca ou nuvem.
    static func organizerAllowed(_ url: URL) -> Bool { BackupEngine.isAllowed(url) }

    func previewOrganizer() async {
        let folder = URL(fileURLWithPath: organizer.folder)
        guard AppState.organizerAllowed(folder) else { organizerPlan = []; return }
        let cfg = organizer
        let token = UUID()
        organizerToken = token
        let plan = await Task.detached { Organizer.plan(folder: folder, cfg: cfg) }.value
        if organizerToken == token { organizerPlan = plan }     // ignora prévias antigas
    }

    func runOrganizer(automatic: Bool = false) async {
        let folder = URL(fileURLWithPath: organizer.folder)
        guard AppState.organizerAllowed(folder), !organizerRunning else { return }
        organizerRunning = true
        let cfg = organizer
        let items = await Task.detached { Organizer.plan(folder: folder, cfg: cfg) }.value
        let r = await Task.detached { Organizer.apply(items) }.value
        if !r.moves.isEmpty {
            // a organização automática soma ao "desfazer" em vez de apagar o da última vez
            organizerUndo = automatic ? organizerUndo + r.moves : r.moves
            if let d = try? JSONEncoder().encode(Array(r.moves.prefix(20000))) { UserDefaults.standard.set(d, forKey: Self.organizerUndoKey) }
        }
        editOrganizer { $0.lastRun = Date() }
        organizerRunning = false
        if !r.moves.isEmpty || !automatic {
            toast = r.moves.isEmpty ? "Nada para organizar — a pasta já está em ordem."
                : "\(r.moves.count) arquivos organizados em \(folder.lastPathComponent)" + (r.failed > 0 ? " · \(r.failed) ficaram no lugar" : "")
        }
        await previewOrganizer()
    }

    func undoOrganizer() async {
        let moves = organizerUndo
        guard !moves.isEmpty else { return }
        let r = await Task.detached { Organizer.undo(moves) }.value
        organizerUndo = []
        UserDefaults.standard.removeObject(forKey: Self.organizerUndoKey)
        toast = "\(r.restored) arquivos voltaram para o lugar" + (r.failed > 0 ? " · \(r.failed) não puderam voltar (o lugar já estava ocupado)" : "")
        await previewOrganizer()
    }

    /// Chamado pelo laço das rotinas: organiza uma vez por dia se estiver ligado.
    func runOrganizerIfDue() async {
        guard organizer.auto else { return }
        if let last = organizer.lastRun, Date().timeIntervalSince(last) < 20 * 3600 { return }
        await runOrganizer(automatic: true)
    }
}

// MARK: - Tela

struct OrganizerView: View {
    @EnvironmentObject var state: AppState
    @State private var confirm = false
    @State private var confirmUndo = false

    private var folderURL: URL { URL(fileURLWithPath: state.organizer.folder) }

    /// Prévia agrupada: pasta de destino → (quantidade, tamanho)
    private var groups: [(String, Int, Int64)] {
        guard let plan = state.organizerPlan else { return [] }
        var d: [String: (Int, Int64)] = [:]
        for it in plan { d[it.group, default: (0, 0)].0 += 1; d[it.group, default: (0, 0)].1 += it.size }
        return d.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                folderCard
                modeCard
                previewCard
            }
            .padding(.horizontal, 30).padding(.bottom, 30)
        }
        .task(id: organizerKey) { await state.previewOrganizer() }
        .confirmationDialog("Organizar \(state.organizerPlan?.count ?? 0) arquivos em \(folderURL.lastPathComponent)?", isPresented: $confirm) {
            Button("Organizar") { Task { await state.runOrganizer() } }
        } message: {
            Text("Os arquivos só mudam de pasta, dentro de \(folderURL.lastPathComponent). Nada é apagado, e dá para desfazer depois.")
        }
        .confirmationDialog("Desfazer a última organização?", isPresented: $confirmUndo) {
            Button("Desfazer") { Task { await state.undoOrganizer() } }
        } message: {
            Text("Os \(state.organizerUndo.count) arquivos voltam para onde estavam, e as pastas criadas que ficarem vazias são removidas.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Section.organize.number).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Rectangle().fill(Color.ink.opacity(0.4)).frame(width: 22, height: 0.8)
                Text("ORGANIZAR").font(.system(size: 11, weight: .semibold)).tracking(2.2)
            }
            .foregroundStyle(Color.ink.opacity(0.74))
            Text("Cada arquivo no seu lugar.").font(.system(size: 30, weight: .light))
            Text("Separa os arquivos soltos por tipo — ou por mês, com os tipos dentro. Só move, nunca apaga, e dá para desfazer.")
                .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76)).frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.top, 30)
    }

    private var folderCard: some View {
        GlassCard(padding: 18) {
            HStack(spacing: 14) {
                Image(nsImage: IconCache.icon(state.organizer.folder)).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderURL.lastPathComponent).font(.system(size: 16, weight: .semibold))
                    Text(state.organizer.folder.replacingOccurrences(of: FS.home.path, with: "~"))
                        .font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                }
                Spacer()
                if folderURL.lastPathComponent != "Downloads" {
                    PillButton(title: "Usar Downloads", prominent: false) {
                        state.editOrganizer { $0.folder = FS.home.appendingPathComponent("Downloads").path }
                    }
                }
                PillButton(title: "Escolher pasta…", icon: "folder", prominent: false) { pickFolder() }
            }
        }
    }

    private var organizerKey: String {
        let c = state.organizer
        return "\(c.folder)|\(c.scheme)|\(c.dateLevel)|\(c.useCreation)|\(c.minAge)|\(c.rename)|\(c.folders)|\(c.ignored.sorted())"
    }

    private let schemes: [(String, String, String, String)] = [
        ("Por tipo", "square.grid.2x2", "Imagens, Vídeos, PDFs, Instaladores…", "Downloads/Imagens/foto.png"),
        ("Data + tipo", "calendar.badge.plus", "Uma pasta por data e, dentro, os tipos", "Downloads/2026-11 novembro/Imagens/…"),
        ("Só por data", "calendar", "Tudo de um período junto", "Downloads/2026-11 novembro/foto.png"),
        ("Por extensão", "textformat.abc", "PDF, PNG, MP4, ZIP… cada um na sua", "Downloads/PDF/contrato.pdf"),
        ("Por origem", "globe", "De onde veio: WhatsApp, Drive, Gmail…", "Downloads/WhatsApp/foto.jpg"),
    ]

    private var modeCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Como organizar").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(schemes.indices, id: \.self) { i in option(i) }
                }

                Divider().overlay(Theme.hairline)
                Text("Ajustes").font(.headline)
                HStack(spacing: 18) {
                    if state.organizer.scheme == 1 || state.organizer.scheme == 2 {
                        labeled("Pastas de data") {
                            Picker("", selection: Binding(get: { state.organizer.dateLevel }, set: { v in state.editOrganizer { $0.dateLevel = v } })) {
                                Text("Por mês").tag(0); Text("Ano › mês").tag(1); Text("Por dia").tag(2)
                            }.labelsHidden().fixedSize()
                        }
                    }
                    labeled("Data usada") {
                        Picker("", selection: Binding(get: { state.organizer.useCreation }, set: { v in state.editOrganizer { $0.useCreation = v } })) {
                            Text("Quando chegou na pasta").tag(false); Text("Quando foi criado").tag(true)
                        }.labelsHidden().fixedSize()
                    }
                    labeled("Só arquivos com mais de") {
                        Stepper(value: Binding(get: { state.organizer.minAge }, set: { v in state.editOrganizer { $0.minAge = v } }), in: 0...365, step: 1) {
                            Text(state.organizer.minAge == 0 ? "todos" : "\(state.organizer.minAge) dias").monospacedDigit()
                        }.fixedSize()
                    }
                    Spacer()
                }
                HStack(spacing: 24) {
                    Toggle("Renomear com a data na frente", isOn: Binding(get: { state.organizer.rename }, set: { v in state.editOrganizer { $0.rename = v } }))
                    Toggle("Organizar também pastas soltas", isOn: Binding(get: { state.organizer.folders }, set: { v in state.editOrganizer { $0.folders = v } }))
                    Spacer()
                }
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Deixar no lugar (não organizar)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.8))
                    FlowChips(items: Organizer.categories.map(\.name), selected: state.organizer.ignored) { name in
                        state.editOrganizer { c in var s = c.ignored; if s.contains(name) { s.remove(name) } else { s.insert(name) }; c.ignored = s }
                    }
                }

                Divider().overlay(Theme.hairline)
                HStack {
                    Toggle("Organizar sozinho todo dia", isOn: Binding(get: { state.organizer.auto },
                                                                     set: { v in state.editOrganizer { $0.auto = v } }))
                        .toggleStyle(.switch)
                    Spacer()
                    if let last = state.organizer.lastRun {
                        Text("Última vez: \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                    }
                }
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.76))
            content()
        }
    }

    private func option(_ i: Int) -> some View {
        let (title, icon, text, example) = schemes[i]
        let on = state.organizer.scheme == i
        return Button { state.editOrganizer { $0.scheme = i } } label: {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: icon, tint: on ? Theme.blue : nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    Text(example).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.ink.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.blue : Color.ink.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink.opacity(on ? 0.06 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Theme.blue.opacity(0.75) : Color.ink.opacity(0.14), lineWidth: on ? 1.2 : 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var previewCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prévia").font(.headline)
                    Spacer()
                    if !state.organizerUndo.isEmpty {
                        PillButton(title: "Desfazer última", icon: "arrow.uturn.backward", prominent: false) { confirmUndo = true }
                    }
                    PillButton(title: state.organizerRunning ? "Organizando…" : "Organizar agora", icon: "wand.and.stars",
                               enabled: !(state.organizerPlan?.isEmpty ?? true) && !state.organizerRunning) { confirm = true }
                }
                if let plan = state.organizerPlan {
                    if plan.isEmpty {
                        Label("Tudo em ordem: não há arquivos soltos para organizar.", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.green).font(.system(size: 13))
                    } else {
                        Text("\(plan.count) arquivos soltos · \(FS.fmt(plan.reduce(0) { $0 + $1.size })) — pastas e arquivos em uso ficam onde estão")
                            .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            ForEach(groups, id: \.0) { g in
                                HStack(spacing: 10) {
                                    IconTile(symbol: Organizer.categories.first { g.0.hasSuffix($0.name) }?.icon ?? "folder", size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(g.0).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text("\(g.1) arquivos · \(FS.fmt(g.2))").font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.74))
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ink.opacity(0.04)))
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Olhando a pasta…").font(.caption) }
                        .foregroundStyle(Color.ink.opacity(0.74))
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar esta pasta"
        panel.message = "Escolha a pasta para organizar"
        if panel.runModal() == .OK, let u = panel.url {
            guard AppState.organizerAllowed(u) else {
                state.toast = "Por segurança, essa pasta não pode ser organizada (sistema, home inteira, Biblioteca ou nuvem)."
                return
            }
            state.editOrganizer { $0.folder = u.path }
        }
    }
}

/// Fichas clicáveis que quebram linha.
struct FlowChips: View {
    let items: [String]
    let selected: Set<String>
    let toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { name in
                let on = selected.contains(name)
                Button { toggle(name) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "pin.fill" : "pin").font(.system(size: 10))
                        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(on ? Color.ink : Color.ink.opacity(0.06)))
                    .foregroundStyle(on ? Color.paper : Color.ink)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
