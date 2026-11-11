import Foundation
import AppKit
import CryptoKit

// MARK: - Modelos

struct FileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    var modified: Date? = nil
}

enum Removal: Sendable { case delete, trash }

struct JunkCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let removal: Removal
    var preselect = true
    let items: [FileItem]
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct DuplicateGroup: Identifiable, Sendable {
    var id: String { hash }
    let hash: String
    /// Ordenado do mais antigo para o mais novo — o primeiro é mantido.
    let files: [FileItem]
    var wasted: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

struct AppEntry: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleID: String
    let size: Int64
}

struct LaunchItem: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let label: String
    let program: String
    let scope: String
    let userOwned: Bool
}

struct CleanResult: Sendable {
    var count = 0
    var freed: Int64 = 0          // tamanho somado dos itens (estimativa)
    var failures: [String] = []
    var trashed: Int64 = 0        // parte que foi para a Lixeira (só libera ao esvaziar)
    var failedPaths: Set<String> = []
    static func + (a: CleanResult, b: CleanResult) -> CleanResult {
        CleanResult(count: a.count + b.count, freed: a.freed + b.freed,
                    failures: a.failures + b.failures, trashed: a.trashed + b.trashed,
                    failedPaths: a.failedPaths.union(b.failedPaths))
    }
}

// MARK: - Utilitários de arquivos

enum FS {
    static let fm = FileManager.default
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let skipDirs: Set<String> = ["node_modules", ".git", ".build", "Library", ".Trash"]

    static func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                if let fv = try? f.resourceValues(forKeys: keys), fv.isRegularFile == true {
                    total += Int64(fv.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    /// Percorre arquivos comuns de uma pasta, pulando pastas de dev, pacotes e ocultos.
    static func walkFiles(_ root: URL, _ body: (URL, Int64, Date?) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                    errorHandler: { _, _ in true }) else { return }
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skipDirs.contains(f.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if v.isRegularFile == true {
                body(f, Int64(v.totalFileAllocatedSize ?? 0), v.contentModificationDate)
            }
        }
    }

    static func remove(_ items: [FileItem], permanently: Bool) -> CleanResult {
        var r = CleanResult()
        for item in items {
            do {
                if permanently { try fm.removeItem(at: item.url) }
                else { try fm.trashItem(at: item.url, resultingItemURL: nil) }
                r.count += 1
                r.freed += item.size
                if !permanently { r.trashed += item.size }
            } catch {
                r.failures.append(item.url.lastPathComponent)
                r.failedPaths.insert(item.url.path)
            }
        }
        return r
    }
}

// MARK: - Scanners

enum Scanner {
    static let home = FS.home

    // Limpeza: caches, logs, lixo de desenvolvimento e instaladores esquecidos
    static func scanJunk() -> [JunkCategory] {
        let ownID = Bundle.main.bundleIdentifier ?? "art.imagostudio.care"

        func dirItems(_ path: String, skipApple: Bool = false) -> [FileItem] {
            FS.children(home.appendingPathComponent(path))
                .filter { !(skipApple && $0.lastPathComponent.hasPrefix("com.apple.")) && $0.lastPathComponent != ownID }
                .map { FileItem(url: $0, size: FS.size(of: $0)) }
                .filter { $0.size > 0 }
                .sorted { $0.size > $1.size }
        }

        func paths(_ list: [String]) -> [FileItem] {
            list.map { home.appendingPathComponent($0) }
                .filter { FS.fm.fileExists(atPath: $0.path) }
                .map { FileItem(url: $0, size: FS.size(of: $0)) }
                .filter { $0.size > 0 }
        }

        var installers: [FileItem] = []
        let installerExt: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
        for f in FS.children(home.appendingPathComponent("Downloads")) where installerExt.contains(f.pathExtension.lowercased()) {
            installers.append(FileItem(url: f, size: FS.size(of: f)))
        }

        let devDeps = projectDependencies()
        let premiere = premiereLeftovers()
        let aiGens = aiGenerations()

        let cats: [JunkCategory] = [
            .init(id: "caches", name: "Caches de apps", detail: "Arquivos temporários que os apps recriam sozinhos",
                  icon: "archivebox.fill", removal: .delete, items: dirItems("Library/Caches", skipApple: true)),
            .init(id: "logs", name: "Logs do usuário", detail: "Registros antigos de atividade dos apps",
                  icon: "doc.text.fill", removal: .delete, items: dirItems("Library/Logs")),
            .init(id: "xcode", name: "Lixo do Xcode", detail: "DerivedData (builds temporários que o Xcode refaz)",
                  icon: "hammer.fill", removal: .delete,
                  items: dirItems("Library/Developer/Xcode/DerivedData")),
            .init(id: "adobe", name: "Cache de mídia Adobe", detail: "Premiere/After Effects recriam sozinhos — feche o Premiere antes",
                  icon: "film.fill", removal: .delete, preselect: false,
                  items: paths(["Library/Application Support/Adobe/Common/Media Cache Files",
                                "Library/Application Support/Adobe/Common/Media Cache",
                                "Library/Application Support/Adobe/Common/Peak Files"])),
            .init(id: "devdeps", name: "Dependências de projetos de código",
                  detail: "node_modules, .next, .venv… de projetos parados. Voltam com npm install / pip install — só apaga se você marcar",
                  icon: "chevron.left.forwardslash.chevron.right", removal: .delete, preselect: false, items: devDeps),
            .init(id: "premiere", name: "Previews e autosaves do Premiere",
                  detail: "Renders de pré-visualização (o Premiere refaz) e autosaves — confira os de projetos ativos",
                  icon: "film.stack.fill", removal: .trash, preselect: false, items: premiere),
            .init(id: "aigen", name: "Gerações de IA esquecidas",
                  detail: "Imagens e vídeos de ferramentas de IA no Downloads e na Mesa — vão para a Lixeira",
                  icon: "wand.and.stars", removal: .trash, preselect: false, items: aiGens),
            .init(id: "mail", name: "Anexos do Mail", detail: "Cópias locais de anexos abertos no Mail — continuam no servidor de e-mail",
                  icon: "envelope.fill", removal: .trash, preselect: false,
                  items: dirItems("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")),
            .init(id: "dev", name: "Caches de desenvolvimento e IA",
                  detail: "npm, pip, modelos de IA baixados… revise: modelos levam tempo para baixar de novo",
                  icon: "terminal.fill", removal: .delete, preselect: false,
                  items: (paths([".npm/_cacache", ".pnpm-store"]) + dirItems(".cache"))
                    .sorted { $0.size > $1.size }),
            .init(id: "installers", name: "Instaladores esquecidos", detail: ".dmg e .pkg na pasta Downloads (vão para a Lixeira)",
                  icon: "shippingbox.fill", removal: .trash, items: installers.sorted { $0.size > $1.size }),
        ]
        return cats.filter { !$0.items.isEmpty }
    }

    /// Pastas de dependências que se recriam sozinhas (só dentro de projetos reconhecíveis).
    static func projectDependencies() -> [FileItem] {
        let markers: [String: [String]] = [
            "node_modules": ["package.json"], ".next": ["package.json"], ".nuxt": ["package.json"],
            ".turbo": ["package.json"], ".parcel-cache": ["package.json"], ".svelte-kit": ["package.json"],
            ".venv": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
            "venv": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
        ]
        let skip: Set<String> = [".git", "Library", ".Trash", "Applications"]
        let roots = ["Documents", "Desktop", "Developer", "Projects", "Code", "dev"].map { home.appendingPathComponent($0) }
        var out: [FileItem] = []
        for root in roots where FS.fm.fileExists(atPath: root.path) {
            let depth0 = root.pathComponents.count
            guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let n = u.lastPathComponent
                if skip.contains(n) || u.pathComponents.count - depth0 > 7 { e.skipDescendants(); continue }
                guard let needs = markers[n] else { continue }
                e.skipDescendants()
                let project = u.deletingLastPathComponent()
                guard needs.contains(where: { FS.fm.fileExists(atPath: project.appendingPathComponent($0).path) }),
                      !CloudEngine.isCloud(u) else { continue }
                let size = FS.size(of: u)
                guard size > 20 * 1024 * 1024 else { continue }
                // última atividade no projeto (arquivos do primeiro nível, fora das dependências)
                var last: Date? = nil
                for f in FS.children(project) where markers[f.lastPathComponent] == nil {
                    if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > (last ?? .distantPast) { last = m }
                }
                out.append(FileItem(url: u, size: size, modified: last))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Pastas de previews/autosave do Premiere espalhadas pelos projetos.
    static func premiereLeftovers() -> [FileItem] {
        let names: Set<String> = ["Adobe Premiere Pro Video Previews", "Adobe Premiere Pro Audio Previews",
                                  "Adobe Premiere Pro Auto-Save", "Adobe Premiere Pro Preview Files",
                                  "Adobe After Effects Auto-Save"]
        let roots = ["Documents", "Desktop", "Movies", "Downloads"].map { home.appendingPathComponent($0) }
        var out: [FileItem] = []
        for root in roots {
            guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                           errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let n = u.lastPathComponent
                if FS.skipDirs.contains(n) { e.skipDescendants(); continue }
                if names.contains(n) {
                    e.skipDescendants()
                    if CloudEngine.isCloud(u) { continue }
                    let size = FS.size(of: u)
                    if size > 0 { out.append(FileItem(url: u, size: size)) }
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Arquivos gerados por ferramentas de IA (pelo nome) no Downloads e na Mesa.
    static let aiMarks = ["generated image", "chatgpt image", "dall-e", "dalle", "midjourney", "higgsfield", "kling",
                          "runway", "leonardo", "firefly", "ideogram", "seedance", "hailuo", "pika", "krea", "imagen",
                          "gemini_generated", "gemini generated", "nano-banana", "nano_banana", "sora", "grok-image", "flux"]
    static let aiMedia: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "mp4", "mov", "gif"]

    /// Nome de arquivo gerado por IA: a marca aparece como palavra inteira (não "sparkling" para "kling").
    static func isAIName(_ name: String) -> Bool {
        let n = name.lowercased()
        return aiMarks.contains { m in
            n.range(of: "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: m) + "([^a-z]|$)", options: .regularExpression) != nil
        }
    }

    static func aiGenerations(topLevelOnly: Bool = false) -> [FileItem] {
        var out: [FileItem] = []
        for root in ["Downloads", "Desktop"].map({ home.appendingPathComponent($0) }) {
            if topLevelOnly {
                for u in FS.children(root) where aiMedia.contains(u.pathExtension.lowercased()) && isAIName(u.lastPathComponent) {
                    let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    if v?.isRegularFile == true { out.append(FileItem(url: u, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate)) }
                }
                continue
            }
            FS.walkFiles(root) { url, size, date in
                if aiMedia.contains(url.pathExtension.lowercased()) && isAIName(url.lastPathComponent) {
                    out.append(FileItem(url: url, size: size, modified: date))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    // Duplicados: mesmo tamanho → mesmo SHA-256
    static func scanDuplicates() -> [DuplicateGroup] {
        let roots = ["Downloads", "Desktop"].map { home.appendingPathComponent($0) }
        var bySize: [Int64: [FileItem]] = [:]
        for root in roots {
            FS.walkFiles(root) { url, size, date in
                guard size > 4096 else { return }
                bySize[size, default: []].append(FileItem(url: url, size: size, modified: date))
            }
        }
        var groups: [DuplicateGroup] = []
        for (_, files) in bySize where files.count > 1 {
            var byHash: [String: [FileItem]] = [:]
            for f in files { if let h = sha256(f.url) { byHash[h, default: []].append(f) } }
            for (h, fs) in byHash where fs.count > 1 {
                groups.append(DuplicateGroup(hash: h, files: fs.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }))
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let expected = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        var hasher = SHA256()
        var total = 0
        do {
            while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d); total += d.count }
        } catch { return nil }                       // erro de leitura: nunca vira "duplicado"
        guard total == expected else { return nil }  // leitura incompleta também não
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Arquivos grandes (> 200 MB) nas pastas do usuário
    static func scanLargeFiles(minSize: Int64 = 200 * 1024 * 1024) -> [FileItem] {
        let roots = ["Downloads", "Desktop", "Documents", "Movies", "Music"].map { home.appendingPathComponent($0) }
        var out: [FileItem] = []
        for root in roots {
            FS.walkFiles(root) { url, size, date in
                if size >= minSize { out.append(FileItem(url: url, size: size, modified: date)) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    // Desinstalador
    static func scanApps() -> [AppEntry] {
        let dirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var apps: [AppEntry] = []
        for dir in dirs {
            for url in FS.children(dir) where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier, !id.hasPrefix("com.apple."),
                      id != Bundle.main.bundleIdentifier else { continue }
                apps.append(AppEntry(url: url, name: url.deletingPathExtension().lastPathComponent,
                                     bundleID: id, size: FS.size(of: url)))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func leftovers(for app: AppEntry) -> [FileItem] {
        let lib = home.appendingPathComponent("Library")
        let subs = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                    "Saved Application State", "Logs", "HTTPStorages", "WebKit", "LaunchAgents",
                    "Application Scripts", "Cookies"]
        let bid = app.bundleID.lowercased()
        let name = app.name.lowercased()
        // bundle ID curto ou genérico pegaria dados de outros apps
        guard bid.count >= 8, bid.split(separator: ".").count >= 3 else { return [] }
        var out: [FileItem] = []
        for sub in subs {
            for url in FS.children(lib.appendingPathComponent(sub)) {
                let n = url.lastPathComponent.lowercased()
                let stem = (n as NSString).deletingPathExtension      // com.app.plist → com.app
                let exact = n == bid || stem == bid
                    || n == bid + ".savedstate" || n == bid + ".binarycookies"
                    || (sub == "Group Containers" && n.hasSuffix("." + bid))     // TEAMID.com.app (sem pegar .beta/.canary)
                if exact || (name.count >= 4 && n == name && sub == "Application Support") {
                    out.append(FileItem(url: url, size: FS.size(of: url)))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    // Itens que rodam na inicialização
    static func scanLaunchItems() -> [LaunchItem] {
        let sources: [(URL, String, Bool)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), "Usuário", true),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "Agente do sistema", false),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "Daemon do sistema", false),
        ]
        var out: [LaunchItem] = []
        for (dir, scope, user) in sources {
            for url in FS.children(dir) where url.pathExtension == "plist" {
                let dict = NSDictionary(contentsOf: url)
                let label = dict?["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                let program = dict?["Program"] as? String
                    ?? (dict?["ProgramArguments"] as? [String])?.first ?? "—"
                out.append(LaunchItem(url: url, label: label, program: program, scope: scope, userOwned: user))
            }
        }
        return out
    }

    static func unloadAndTrash(_ item: LaunchItem) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())", item.url.path]
        try? p.run(); p.waitUntilExit()
        return (try? FS.fm.trashItem(at: item.url, resultingItemURL: nil)) != nil
    }

    /// Roda um comando com senha de administrador (o macOS mostra a janela de senha).
    static let adminCommands: Set<String> = [
        "/usr/sbin/purge",
        "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder",
        "/usr/bin/tmutil deletelocalsnapshots /",
    ]

    static func runAdmin(_ cmd: String) -> String? {
        // só comandos fixos e conhecidos rodam como administrador
        guard adminCommands.contains(cmd) else { return "Comando não permitido" }
        let safe = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return osascript("do shell script \"\(safe)\" with administrator privileges")
    }

    /// Roda AppleScript num processo separado (não trava a tela). Retorna a mensagem de erro, se houver.
    static func osascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return msg.contains("-128") ? "cancelado" : (msg.isEmpty ? "falhou" : msg)
    }
}

// MARK: - Ferramentas extras

enum Extras {
    static var trashURL: URL { FS.home.appendingPathComponent(".Trash") }

    /// Tamanho da Lixeira (nil se o macOS não deixar ler sem Acesso Total ao Disco).
    static func trashSize() -> Int64? {
        guard (try? FS.fm.contentsOfDirectory(atPath: trashURL.path)) != nil else { return nil }
        return FS.size(of: trashURL)
    }

    static func emptyTrash() -> String? {
        Scanner.osascript("tell application \"Finder\" to empty trash")
    }

    /// Quantidade de capturas locais do Time Machine no disco principal.
    static func localSnapshots() -> Int {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }
}
