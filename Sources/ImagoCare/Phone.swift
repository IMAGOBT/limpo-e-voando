import SwiftUI
import AppKit
import ImageCaptureCore
import Vision
import ImageIO

// MARK: - Modelos

enum PhoneKind: String { case photo, video, screenshot }

struct PhoneFile: Identifiable {
    var uid: String? = nil       // usado só quando o id se repete no aparelho
    var id: String { uid ?? key }
    let key: String              // pasta/nome|tamanho|data — identifica o arquivo entre conexões
    let file: ICCameraFile
    let name: String
    let size: Int64
    let date: Date?
    let kind: PhoneKind
    let isLive: Bool
    var imported: Bool

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isBigVideo: Bool { kind == .video && size >= 200 * 1024 * 1024 }
}

struct PhoneProgress {
    var phase = ""
    var done = 0
    var total = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : (total > 0 ? Double(done) / Double(total) : 0) }
}

// MARK: - Conexão com iPhone / Android (ImageCaptureCore, o mesmo motor do app Captura de Imagem)

@MainActor
final class PhoneHub: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    @Published var devices: [ICCameraDevice] = []
    @Published var current: ICCameraDevice?
    @Published var files: [PhoneFile] = []
    @Published var loading = false
    @Published var locked = false
    @Published var working = false
    @Published var progress = PhoneProgress()
    @Published var message: String?

    private let browser = ICDeviceBrowser()
    private var started = false
    private static let ledgerKey = "phone.imported.v1"
    private var ledger: Set<String> = Set(UserDefaults.standard.stringArray(forKey: PhoneHub.ledgerKey) ?? [])

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    func select(_ d: ICCameraDevice) {
        if current === d { return }
        current?.requestCloseSession()
        current = d
        files = []
        loading = true
        locked = false
        d.delegate = self
        d.requestOpenSession()
    }

    // MARK: Navegador de aparelhos

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let cam = device as? ICCameraDevice, !self.devices.contains(where: { $0 === cam }) else { return }
            self.devices.append(cam)
            if self.current == nil { self.select(cam) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            self.devices.removeAll { $0 === device }
            if self.current === device { self.current = nil; self.files = []; self.loading = false; self.disconnected = true }
            if self.current == nil, let next = self.devices.first { self.select(next) }
        }
    }

    // MARK: Aparelho

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error { self.message = "Não consegui abrir o aparelho: \(error.localizedDescription)"; self.loading = false }
            if (device as? ICCameraDevice)?.isAccessRestrictedAppleDevice == true { self.locked = true }
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            guard device === self.current else { return }
            self.locked = false
            let all = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
            let sidecars = Set(all.flatMap { ($0.sidecarFiles ?? []).map { ObjectIdentifier($0) } })
            self.files = all
                .filter { !sidecars.contains(ObjectIdentifier($0)) && (($0.name ?? "") as NSString).pathExtension.lowercased() != "aae" }
                .map(self.makeFile)
            // garante ids únicos (o iPhone pode ter arquivos idênticos em pastas diferentes)
            var seen: [String: Int] = [:]
            self.files = self.files.map { f in
                let n = (seen[f.id] ?? 0) + 1
                seen[f.id] = n
                guard n > 1 else { return f }
                var g = f
                g.uid = "\(f.id)#\(n)"
                return g
            }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            self.loading = false
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.locked = true }
    }
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in
            self.locked = false
            if let cam = device as? ICCameraDevice, cam === self.current { self.loading = true; cam.requestOpenSession() }
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    private func makeFile(_ f: ICCameraFile) -> PhoneFile {
        let name = f.name ?? "arquivo"
        let ext = (name as NSString).pathExtension.lowercased()
        let date = f.exifCreationDate ?? f.fileCreationDate ?? f.creationDate
        let kind: PhoneKind = ["mov", "mp4", "m4v", "3gp"].contains(ext) ? .video : (ext == "png" ? .screenshot : .photo)
        let folder = f.parentFolder?.name ?? ""
        let key = "\(folder)/\(name)|\(f.fileSize)|\(Int(date?.timeIntervalSince1970 ?? 0))"
        let live = (f.sidecarFiles ?? []).contains { ($0.name ?? "").lowercased().hasSuffix(".mov") }
        return PhoneFile(key: key, file: f, name: name, size: Int64(f.fileSize), date: date, kind: kind,
                         isLive: live, imported: ledger.contains(key))
    }

    // MARK: Análise (assunto e parecidos) — tudo no Mac, nada sai do computador

    @Published var subjects: [String: String] = (UserDefaults.standard.dictionary(forKey: "phone.subjects.v1") as? [String: String]) ?? [:]
    @Published var groups: [[String]] = []          // grupos de fotos iguais/parecidas (ids); o 1º é o "melhor"
    @Published var analyzing = false
    @Published var analysisDone = 0
    @Published var analysisTotal = 0
    @Published var analyzed = false
    @Published var freedOnPhone: Int64 = 0
    var disconnected = false
    var stopAnalysis = false

    static let subjectOrder = ["Pessoas", "Documentos", "Prints", "Comida", "Natureza e lugares", "Animais",
                               "Veículos", "Telas", "Ambientes", "Outros"]
    static let subjectIcons: [String: String] = [
        "Pessoas": "person.2", "Documentos": "doc.text.viewfinder", "Prints": "camera.viewfinder", "Comida": "fork.knife",
        "Natureza e lugares": "leaf", "Animais": "pawprint", "Veículos": "car", "Telas": "display", "Ambientes": "sofa", "Outros": "square.grid.2x2",
    ]

    func analyze() async {
        guard !analyzing, !files.isEmpty else { return }
        analyzing = true
        stopAnalysis = false
        let items = files
        analysisTotal = items.count
        analysisDone = 0
        var allPrints: [PhoneVision.Print] = []
        var known = subjects
        // em lotes de 150: baixa as miniaturas, analisa e descarta (memória baixa)
        var i = 0
        while i < items.count && !stopAnalysis && current != nil {
            let chunk = items[i..<min(i + 150, items.count)]
            var thumbs: [(String, Data, PhoneKind, Int64, Date?)] = []
            for it in chunk {
                if stopAnalysis || current == nil { break }
                if let d = await thumbnailData(it.file) { thumbs.append((it.id, d, it.kind, it.size, it.date)) }
                analysisDone += 1
            }
            let k = known
            let part = await Task.detached { PhoneVision.classify(thumbs, known: k) }.value
            subjects.merge(part.subjects) { _, new in new }
            known.merge(part.subjects) { _, new in new }
            allPrints += part.prints
            i += 150
        }
        let prints = allPrints
        groups = await Task.detached { PhoneVision.group(prints) }.value
        UserDefaults.standard.set(subjects, forKey: "phone.subjects.v1")
        analyzing = false
        analyzed = true
        message = stopAnalysis ? "Análise interrompida — o que foi analisado já aparece nas abas"
            : "Análise pronta: \(Set(subjects.values).count) assuntos e \(groups.count) grupos de fotos parecidas"
    }

    private func thumbnailData(_ f: ICCameraFile) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let box = OnceBox(cont)
            f.requestThumbnailData(options: [:]) { d, _ in box.resume(d) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { box.resume(nil) }
        }
    }

    // MARK: Importar (organizado por ano/mês, renomeado pela data da foto)

    static func monthFolder(_ d: Date) -> (String, String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "yyyy"; let y = f.string(from: d)
        f.dateFormat = "MM LLLL"; return (y, f.string(from: d))
    }

    static func baseName(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: d)
    }

    private func download(_ f: ICCameraFile, to dir: URL, name: String) async -> URL? {
        let timeout = max(120, Double(f.fileSize) / 2_000_000)   // ~2 MB/s no pior caso
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let box = OnceBox(cont)
            let p = f.requestDownload(options: [.downloadsDirectoryURL: dir, .saveAsFilename: name, .overwrite: false]) { saved, err in
                box.resume(err == nil ? dir.appendingPathComponent(saved ?? name) : nil)
            }
            if p == nil { box.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.resume(nil) }   // iPhone travou ou desconectou
        }
    }

    /// Importa para `root/AAAA/MM mês/AAAA-MM-DD_HH-mm-ss.ext`. Se `root` estiver no Drive, espera o envio
    /// e libera o espaço do Mac em lotes (o Mac nunca enche).
    func importFiles(_ items: [PhoneFile], to root: URL, bySubject: Bool = false) async {
        guard !working else { return }
        working = true
        let toDo = items.filter { !$0.imported }
        progress = PhoneProgress(phase: "Preparando…", total: toDo.count, bytesTotal: toDo.reduce(0) { $0 + $1.size })
        let cloud = CloudEngine.isCloud(root)
        var pending: [URL] = []
        var pendingBytes: Int64 = 0
        var owner: [URL: String] = [:]          // arquivo salvo → id da foto no celular
        var ok = 0, failed = 0
        func confirm(_ confirmed: Set<URL>) {
            for u in confirmed { if let id = owner[u] { mark(id) } }
        }

        disconnected = false
        for item in toDo {
            if disconnected { failed += toDo.count - progress.done; break }   // iPhone desconectado
            if cloud, !pending.isEmpty, pendingBytes + item.size > BackupEngine.batchLimit || Disk.free() < item.size + BackupEngine.reserve {
                progress.phase = "Enviando para o Google Drive…"
                confirm(await flush(pending)); pending = []; pendingBytes = 0
            }
            if Disk.free() < item.size + BackupEngine.reserve { failed += 1; progress.done += 1; continue }

            let date = item.date ?? Date()
            let (y, m) = PhoneHub.monthFolder(date)
            let dir = bySubject
                ? root.appendingPathComponent(subjects[item.id] ?? (item.kind == .screenshot ? "Prints" : "Outros")).appendingPathComponent(y).appendingPathComponent(m)
                : root.appendingPathComponent(y).appendingPathComponent(m)
            try? FS.fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var base = PhoneHub.baseName(date)
            var n = 2
            while FS.fm.fileExists(atPath: dir.appendingPathComponent("\(base).\(item.ext)").path) {
                base = "\(PhoneHub.baseName(date))_\(n)"; n += 1
            }
            progress.phase = "Copiando \(item.name)…"
            if let saved = await download(item.file, to: dir, name: "\(base).\(item.ext)") {
                try? FS.fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: saved.path)
                pending.append(saved); pendingBytes += item.size
                owner[saved] = item.id
                // Live Photo: o vídeo curto vai junto, com o mesmo nome
                for side in (item.file.sidecarFiles ?? []).compactMap({ $0 as? ICCameraFile }) {
                    let sext = ((side.name ?? "") as NSString).pathExtension.lowercased()
                    if let s = await download(side, to: dir, name: "\(base).\(sext)") { pending.append(s) }
                }
                if !cloud { mark(item.id) }        // fora da nuvem: copiado = importado
                ok += 1
            } else {
                failed += 1
            }
            progress.done += 1
            progress.bytesDone += item.size
        }
        if cloud && !pending.isEmpty { progress.phase = "Enviando para o Google Drive…"; confirm(await flush(pending)) }
        UserDefaults.standard.set(Array(ledger.suffix(200_000)), forKey: PhoneHub.ledgerKey)
        working = false
        message = "\(ok) arquivos importados e organizados" + (failed > 0 ? " · \(failed) não puderam ser copiados" : "")
            + (cloud ? " · já estão no Google Drive" : "")
    }

    private func mark(_ id: String) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        ledger.insert(files[i].key)          // o registro usa a chave estável (pasta/nome|tamanho|data)
        files[i].imported = true
    }

    /// Espera o Drive confirmar o envio e tira a cópia local (até 2 h por lote). Devolve o que foi confirmado.
    private func flush(_ urls: [URL]) async -> Set<URL> {
        var waiting = Set(urls)
        var confirmed = Set<URL>()
        let limit = Date().addingTimeInterval(2 * 3600)
        while !waiting.isEmpty && Date() < limit {
            for u in waiting {
                let st = await Task.detached { CloudEngine.uploadState(u) }.value
                if st.error != nil { waiting.remove(u) }
                else if st.done {
                    _ = await Task.detached { CloudEngine.evict(u) }.value
                    waiting.remove(u); confirmed.insert(u)
                }
            }
            if !waiting.isEmpty { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        return confirmed
    }

    /// O aparelho permite apagar pelo Mac?
    var canDelete: Bool {
        current?.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) ?? false
    }

    // MARK: Apagar do celular (só o que já foi importado)

    func deleteFromPhone(_ items: [PhoneFile], includeNotImported: Bool = false) async {
        guard let cam = current, !working else { return }
        let safe = includeNotImported ? items : items.filter(\.imported)
        guard !safe.isEmpty else { message = "Nada para apagar: importe primeiro."; return }
        working = true
        progress = PhoneProgress(phase: "Apagando do celular…", total: safe.count)
        final class Failed: @unchecked Sendable { let lock = NSLock(); var ids = Set<ObjectIdentifier>(); var timedOut = false }
        let failed = Failed()
        let finished: Bool = await withCheckedContinuation { cont in
            let box = OnceBox(cont)
            cam.requestDeleteFiles(safe.map(\.file), deleteFailed: { info in
                failed.lock.lock(); info.values.forEach { failed.ids.insert(ObjectIdentifier($0)) }; failed.lock.unlock()
            }, completion: { _, _ in box.resume(true) })
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { box.resume(false) }
        }
        failed.lock.lock(); let failedIDs = failed.ids; failed.lock.unlock()
        // só tira da lista o que foi apagado de fato
        let deleted = finished ? safe.filter { !failedIDs.contains(ObjectIdentifier($0.file)) } : []
        let removedIDs = Set(deleted.map(\.id))
        let freed = deleted.reduce(0) { $0 + $1.size }
        files.removeAll { removedIDs.contains($0.id) }
        groups = groups.map { $0.filter { !removedIDs.contains($0) } }.filter { $0.count > 1 }
        freedOnPhone += freed
        working = false
        if !finished {
            message = "O iPhone não respondeu. Desbloqueie-o e confira; nada além do confirmado foi tirado da lista."
        } else {
            message = deleted.count == safe.count
                ? "\(deleted.count) arquivos apagados do celular · \(FS.fmt(freed)) liberados no iPhone"
                : "\(deleted.count) apagados, \(safe.count - deleted.count) não. O iPhone pode pedir confirmação na tela."
        }
    }
}

/// Garante que uma continuação seja retomada uma única vez (callback do iPhone OU prazo).
final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<T, Never>
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: v)
    }
}

// MARK: - Visão computacional (classificação e semelhança)

enum PhoneVision {
    struct Result { var subjects: [String: String] = [:]; var groups: [[String]] = [] }

    static func subject(labels: [String], faces: Int, kind: PhoneKind) -> String {
        if kind == .screenshot { return "Prints" }
        func has(_ words: [String]) -> Bool { labels.contains { l in words.contains { l.contains($0) } } }
        if faces > 0 || has(["people", "person", "selfie", "portrait", "child", "baby", "crowd"]) { return "Pessoas" }
        if has(["document", "receipt", "paper", "text", "handwriting", "menu", "book", "whiteboard", "sign", "poster", "screenshot", "printed"]) { return "Documentos" }
        if has(["food", "meal", "dish", "drink", "dessert", "fruit", "coffee", "pizza", "bread", "cake", "beverage", "vegetable"]) { return "Comida" }
        if has(["animal", "dog", "cat", "bird", "pet", "horse", "fish", "mammal"]) { return "Animais" }
        if has(["vehicle", "car", "motorcycle", "bicycle", "truck", "bus", "automobile"]) { return "Veículos" }
        if has(["screen", "monitor", "computer", "television", "display", "laptop", "phone", "electronics"]) { return "Telas" }
        if has(["sky", "outdoor", "landscape", "mountain", "beach", "sunset", "plant", "tree", "flower", "water", "nature",
                "forest", "sea", "ocean", "lake", "park", "garden", "cityscape", "street", "snow"]) { return "Natureza e lugares" }
        if has(["structure", "building", "interior", "room", "furniture", "kitchen", "office", "architecture", "house"]) { return "Ambientes" }
        return "Outros"
    }

    struct Print: @unchecked Sendable { let id: String; let fp: VNFeaturePrintObservation; let size: Int64; let date: Date? }
    struct Part: @unchecked Sendable { var subjects: [String: String] = [:]; var prints: [Print] = [] }

    static func classify(_ thumbs: [(String, Data, PhoneKind, Int64, Date?)], known: [String: String]) -> Part {
        var r = Part()
        for (id, data, kind, size, date) in thumbs {
            autoreleasepool {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                let classify = VNClassifyImageRequest()
                let faces = VNDetectFaceRectanglesRequest()
                let feature = VNGenerateImageFeaturePrintRequest()
                var reqs: [VNRequest] = [feature]
                if known[id] == nil { reqs += [classify, faces] }
                try? handler.perform(reqs)
                if known[id] == nil {
                    let labels = (classify.results ?? []).filter { $0.confidence > 0.25 }.map { $0.identifier.lowercased() }
                    r.subjects[id] = subject(labels: labels, faces: faces.results?.count ?? 0, kind: kind)
                }
                if let fp = feature.results?.first { r.prints.append(Print(id: id, fp: fp, size: size, date: date)) }
            }
        }
        return r
    }

    static func group(_ prints: [Print]) -> [[String]] {
        var r = Result()
        // Semelhantes: compara cada foto com as tiradas logo em seguida (até 10 min) e cópias de mesmo tamanho
        var parent: [String: String] = [:]
        func find(_ x: String) -> String { var x = x; while let p = parent[x], p != x { x = p }; return x }
        func union(_ a: String, _ b: String) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }
        for p in prints { parent[p.id] = p.id }
        func dist(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
            var d: Float = 99; try? a.computeDistance(&d, to: b); return d
        }
        let byDate = prints.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        for i in byDate.indices {
            var j = i + 1
            while j < byDate.count, j < i + 25 {
                if let a = byDate[i].date, let b = byDate[j].date, b.timeIntervalSince(a) > 600 { break }
                if dist(byDate[i].fp, byDate[j].fp) < 0.35 { union(byDate[i].id, byDate[j].id) }
                j += 1
            }
        }
        var bySize: [Int64: [Int]] = [:]
        for (k, p) in prints.enumerated() { bySize[p.size, default: []].append(k) }
        for (_, idx) in bySize where idx.count > 1 {
            for a in idx { for b in idx where b > a {
                if dist(prints[a].fp, prints[b].fp) < 0.08 { union(prints[a].id, prints[b].id) }
            } }
        }
        var buckets: [String: [String]] = [:]
        for p in prints { buckets[find(p.id), default: []].append(p.id) }
        let sizeOf = Dictionary(prints.map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
        r.groups = buckets.values.map { Array(Set($0)) }.filter { $0.count > 1 }
            .map { $0.sorted { (sizeOf[$0] ?? 0) > (sizeOf[$1] ?? 0) } }   // maior arquivo primeiro = "melhor"
            .sorted { $0.count > $1.count }
        return r.groups
    }
}

// MARK: - Miniatura

struct PhoneThumb: View {
    let file: PhoneFile
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: file.kind == .video ? "film" : file.kind == .screenshot ? "camera.viewfinder" : "photo")
                    .foregroundStyle(Color.ink.opacity(0.5))
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: file.id) {
            guard image == nil else { return }
            let data: Data? = await withCheckedContinuation { cont in
                file.file.requestThumbnailData(options: [:]) { d, _ in cont.resume(returning: d) }
            }
            if let data { image = NSImage(data: data) }
        }
    }
}

// MARK: - Tela

struct PhoneView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneHub
    @State private var tab = 0          // 0 novos · 1 mais pesados · 2 por mês · 3 por assunto · 4 parecidos · 5 prints · 6 já no Drive
    @State private var subject: String?
    @State private var picked: Set<String> = []
    @State private var bySubject = false
    @State private var confirmImport = false
    @State private var confirmDelete = false
    @State private var confirmDeleteAll = false

    private let tabs = ["Novos", "Mais pesados", "Por mês", "Por assunto", "Parecidos", "Prints", "Já no Drive"]

    private var destination: URL {
        if let d = state.driveRoot { return d.appendingPathComponent("Fotos do celular") }
        return FS.home.appendingPathComponent("Pictures/Fotos do celular")
    }

    private var shown: [PhoneFile] {
        switch tab {
        case 0: return phone.files.filter { !$0.imported }
        case 1: return phone.files.sorted { $0.size > $1.size }
        case 3: return phone.files.filter { subject == nil || phone.subjects[$0.id] == subject }
        case 5: return phone.files.filter { $0.kind == .screenshot }
        case 6: return phone.files.filter(\.imported)
        default: return phone.files
        }
    }

    private var selection: [PhoneFile] { phone.files.filter { picked.contains($0.id) } }
    private var byID: [String: PhoneFile] { Dictionary(phone.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let d = phone.current {
                if phone.locked { lockedCard(d) }
                else if phone.loading { loadingCard(d) }
                else { deviceContent }
            } else {
                noDeviceCard
            }
        }
        .padding(.horizontal, 30).padding(.bottom, 20)
        .onAppear { phone.start() }
        .onChange(of: phone.message) { m in if let m { state.toast = m; phone.message = nil } }
        .confirmationDialog("Importar \(importList.count) arquivos para \(state.driveRoot != nil ? "o Google Drive" : "Imagens")?", isPresented: $confirmImport) {
            Button("Importar e organizar") {
                let l = importList, subj = bySubject
                Task { await phone.importFiles(l, to: destination, bySubject: subj); picked = [] }
            }
        } message: {
            Text("Vão para \(destination.path.replacingOccurrences(of: FS.home.path, with: "~"))/\(bySubject ? "Assunto/" : "")AAAA/MM mês, renomeados pela data (ex.: 2026-11-10_18-31-05.heic). O que já foi importado é pulado. Nada é apagado do celular.")
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            if selection.contains(where: \.imported) {
                Button("Apagar só os que já estão no Drive (\(selection.filter(\.imported).count))", role: .destructive) {
                    let l = selection; Task { await phone.deleteFromPhone(l); picked = [] }
                }
            }
            if selection.contains(where: { !$0.imported }) {
                Button("Apagar todos os \(selection.count), inclusive os não salvos…", role: .destructive) { confirmDeleteAll = true }
            }
        } message: {
            Text("Atenção: se o iPhone usa Fotos do iCloud, apagar aqui apaga também do iCloud. O iPhone pode pedir confirmação na tela.")
        }
        .confirmationDialog("Apagar \(selection.filter { !$0.imported }.count) arquivos que NÃO estão salvos no Drive?", isPresented: $confirmDeleteAll) {
            Button("Apagar mesmo assim", role: .destructive) {
                let l = selection; Task { await phone.deleteFromPhone(l, includeNotImported: true); picked = [] }
            }
        } message: {
            Text("Esses arquivos não têm cópia no Drive. Use para prints e vídeos que você não quer guardar.")
        }
    }

    private var deleteTitle: String {
        let imp = selection.filter(\.imported).count, not = selection.count - imp
        return not == 0 ? "Apagar \(imp) arquivos do iPhone? (já estão no Drive)"
                        : "\(imp) dos \(selection.count) selecionados já estão no Drive"
    }

    private var importList: [PhoneFile] {
        let sel = selection.filter { !$0.imported }
        return sel.isEmpty ? phone.files.filter { !$0.imported } : sel
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Section.phone.number).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Rectangle().fill(Color.ink.opacity(0.4)).frame(width: 22, height: 0.8)
                Text("MAC + IPHONE").font(.system(size: 11, weight: .semibold)).tracking(2.2)
                Text("BÔNUS · TESTE").font(.system(size: 10, weight: .bold)).tracking(1.4)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.orange.opacity(0.16)))
                    .foregroundStyle(Theme.orange)
                Spacer()
                if let d = phone.current {
                    Label(d.name ?? "iPhone", systemImage: "iphone").font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(Color.ink.opacity(0.74))
            Text("Organize o iPhone, apague o que não quer e mande o resto para o Drive.").font(.system(size: 26, weight: .light))
        }
        .padding(.top, 26)
    }

    private var noDeviceCard: some View {
        GlassCard(padding: 24) {
            HStack(alignment: .top, spacing: 30) {
                GlassHero(symbol: "iphone", tint: Theme.blue, radius: 60, size: 150)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Procurando o iPhone…").font(.system(size: 13)) }
                        .foregroundStyle(Color.ink.opacity(0.76))
                    step(1, "Conecte o iPhone no Mac com um cabo de dados.")
                    step(2, "Desbloqueie o iPhone e toque em \"Confiar\".")
                    step(3, "As fotos e os vídeos aparecem aqui.")
                    Divider().overlay(Theme.hairline)
                    Label("Dica: em Ajustes › Fotos › Transferir para Mac ou PC, escolha \"Manter originais\" (mantém HEIC).", systemImage: "lightbulb")
                        .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    Label("Android também funciona para as fotos da câmera (modo \"Transferir fotos\").", systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Color.ink.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.paper)
                .frame(width: 22, height: 22).background(Circle().fill(Color.ink))
            Text(text).font(.system(size: 14))
        }
    }

    private func lockedCard(_ d: ICCameraDevice) -> some View {
        GlassCard(padding: 24) {
            HStack(spacing: 16) {
                IconTile(symbol: "lock.iphone", size: 44, tint: Theme.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Desbloqueie o \(d.name ?? "iPhone")").font(.system(size: 16, weight: .semibold))
                    Text("Com ele desbloqueado e \"Confiar\" aceito, as fotos aparecem aqui.").foregroundStyle(Color.ink.opacity(0.76))
                }
            }
        }
    }

    private func loadingCard(_ d: ICCameraDevice) -> some View {
        GlassCard(padding: 24) {
            HStack(spacing: 14) {
                ProgressView()
                Text("Lendo as fotos de \(d.name ?? "iPhone")… com muitas fotos leva alguns minutos.").foregroundStyle(Color.ink.opacity(0.8))
            }
        }
    }

    // MARK: Conteúdo

    private var deviceContent: some View {
        let all = phone.files
        let videos = all.filter { $0.kind == .video }, shots = all.filter { $0.kind == .screenshot }
        let photos = all.filter { $0.kind == .photo }, imported = all.filter(\.imported)
        return VStack(alignment: .leading, spacing: 12) {
            // Resumo
            HStack(spacing: 10) {
                stat("Fotos", photos, Theme.blue)
                stat("Vídeos", videos, Theme.purple)
                stat("Prints", shots, Theme.orange)
                stat("Já no Drive", imported, Theme.green)
                if phone.freedOnPhone > 0 {
                    GlassCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liberado no iPhone").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.8))
                            Text(FS.fmt(phone.freedOnPhone)).font(.system(size: 20, weight: .light)).foregroundStyle(Theme.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Abas
            HStack(spacing: 4) {
                ForEach(tabs.indices, id: \.self) { i in tabButton(tabs[i], i) }
                Spacer()
                Button(picked.isEmpty ? "Selecionar todos" : "Limpar seleção (\(picked.count))") {
                    picked = picked.isEmpty ? Set(visibleIDs) : []
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.blue)
            }

            if (tab == 3 || tab == 4) && !phone.analyzed { analysisCard }
            if tab == 3 && phone.analyzed { subjectChips }
            if phone.working { progressCard }

            GlassCard(padding: 12) {
                ScrollView {
                    switch tab {
                    case 2: monthGrid
                    case 4: similarList
                    default: grid(shown)
                    }
                }
            }

            // Ações
            HStack(spacing: 12) {
                Text(picked.isEmpty ? "\(all.filter { !$0.imported }.count) novos para importar"
                                    : "\(picked.count) selecionados · \(FS.fmt(selection.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink.opacity(0.8))
                Spacer()
                HStack(spacing: 6) {
                    Text("Organizar no Drive por").font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    Picker("", selection: $bySubject) { Text("Data").tag(false); Text("Assunto").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .disabled(!phone.analyzed && true)
                        .help(phone.analyzed ? "" : "Para organizar por assunto, rode a análise (aba Por assunto)")
                }
                if phone.canDelete {
                    PillButton(title: "Apagar do iPhone", icon: "trash", prominent: false,
                               enabled: !phone.working && !picked.isEmpty) { confirmDelete = true }
                }
                PillButton(title: picked.isEmpty ? "Importar todos os novos" : "Importar selecionados", icon: "icloud.and.arrow.up",
                           enabled: !phone.working && !importList.isEmpty) { confirmImport = true }
            }
        }
    }

    private var visibleIDs: [String] {
        switch tab {
        case 2: return phone.files.map(\.id)
        case 4: return phone.groups.flatMap { $0.dropFirst() }   // seleciona as cópias, mantém a melhor
        default: return shown.map(\.id)
        }
    }

    private var analysisCard: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "sparkle.magnifyingglass", size: 38, tint: Theme.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab == 3 ? "Separar por assunto" : "Achar fotos iguais e parecidas").font(.system(size: 14, weight: .semibold))
                    Text("Analisa as miniaturas aqui no Mac (nada vai para a internet). Leva 1–3 minutos.")
                        .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                }
                Spacer()
                if phone.analyzing {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(phone.analysisDone) de \(phone.analysisTotal)").font(.caption).monospacedDigit()
                        ProgressView(value: Double(phone.analysisDone), total: Double(max(phone.analysisTotal, 1))).tint(Theme.blue).frame(width: 160)
                        Button("Parar") { phone.stopAnalysis = true }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.red)
                    }
                } else {
                    PillButton(title: "Analisar agora", icon: "wand.and.stars") { Task { await phone.analyze() } }
                }
            }
        }
    }

    private var subjectChips: some View {
        let counts = Dictionary(grouping: phone.files, by: { phone.subjects[$0.id] ?? "Outros" })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Todos", "square.grid.2x2", phone.files.count, subject == nil) { subject = nil }
                ForEach(PhoneHub.subjectOrder.filter { counts[$0] != nil }, id: \.self) { s in
                    chip(s, PhoneHub.subjectIcons[s] ?? "folder", counts[s]?.count ?? 0, subject == s) { subject = s }
                }
            }
        }
    }

    private func chip(_ title: String, _ icon: String, _ n: Int, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .medium))
                Text("\(n)").font(.system(size: 11)).monospacedDigit().opacity(0.7)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(on ? Color.ink : Color.ink.opacity(0.06)))
            .foregroundStyle(on ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }

    private var progressCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(phone.progress.phase).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Text("\(Int(phone.progress.fraction * 100))%").monospacedDigit().font(.system(size: 13, weight: .medium))
                }
                ProgressView(value: phone.progress.fraction).tint(Theme.blue)
                Text("\(phone.progress.done) de \(phone.progress.total) · deixe o iPhone conectado e o app aberto")
                    .font(.caption).foregroundStyle(Color.ink.opacity(0.74))
            }
        }
    }

    private func grid(_ items: [PhoneFile]) -> some View {
        Group {
            if items.isEmpty {
                Text(tab == 0 ? "Tudo já foi importado. 🎉" : "Nada aqui.")
                    .foregroundStyle(Color.ink.opacity(0.76)).frame(maxWidth: .infinity).padding(30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                    ForEach(items.prefix(3000)) { f in cell(f) }
                }
            }
        }
    }

    private var monthGrid: some View {
        let fmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "LLLL 'de' yyyy"; return f }()
        let groups = Dictionary(grouping: phone.files) { f -> String in
            guard let d = f.date else { return "0000-00" }
            let c = Calendar.current.dateComponents([.year, .month], from: d)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        }
        let keys = groups.keys.sorted(by: >)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8, pinnedViews: [.sectionHeaders]) {
            ForEach(keys, id: \.self) { k in
                let items = (groups[k] ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                SwiftUI.Section {
                    ForEach(items) { f in cell(f) }
                } header: {
                    let ids = Set(items.map(\.id))
                    let all = ids.isSubset(of: picked)
                    HStack {
                        Text(k == "0000-00" ? "Sem data" : (items.first?.date.map { fmt.string(from: $0).capitalized } ?? k))
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(items.count) itens · \(FS.fmt(items.reduce(0) { $0 + $1.size }))")
                            .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.74))
                        Spacer()
                        Button(all ? "Desmarcar mês" : "Selecionar mês") {
                            if all { picked.subtract(ids) } else { picked.formUnion(ids) }
                        }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.blue)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 4)
                    .background(Color.paper.opacity(0.92))
                }
            }
        }
    }

    private var similarList: some View {
        let map = byID
        return LazyVStack(alignment: .leading, spacing: 14) {
            if phone.analyzed && phone.groups.isEmpty {
                Text("Nenhuma foto repetida ou parecida encontrada. 🎉").foregroundStyle(Color.ink.opacity(0.76)).padding(30)
            }
            ForEach(Array(phone.groups.prefix(300).enumerated()), id: \.offset) { _, g in
                let items = g.compactMap { map[$0] }
                if items.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(items.count) parecidas · \(FS.fmt(items.dropFirst().reduce(0) { $0 + $1.size })) nas cópias")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button("Marcar cópias") { picked.formUnion(items.dropFirst().map(\.id)) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.blue)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                                    cell(f).overlay(alignment: .top) {
                                        if i == 0 {
                                            Text("MELHOR").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.green)).offset(y: -6)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func cell(_ f: PhoneFile) -> some View {
        let on = picked.contains(f.id)
        return VStack(alignment: .leading, spacing: 4) {
            PhoneThumb(file: f)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17)).foregroundStyle(on ? Theme.blue : .white)
                        .shadow(color: .black.opacity(0.5), radius: 2).padding(5)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 3) {
                        if f.imported { Image(systemName: "checkmark.icloud.fill") }
                        if f.isLive { Text("LIVE").font(.system(size: 8, weight: .bold)) }
                        if f.kind == .video { Image(systemName: "video.fill") }
                    }
                    .font(.system(size: 10)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2).padding(5)
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Theme.blue : .clear, lineWidth: 2))
            Text(f.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? f.name)
                .font(.system(size: 10.5)).foregroundStyle(Color.ink.opacity(0.74)).lineLimit(1)
            Text(FS.fmt(f.size)).font(.system(size: 10, weight: tab == 1 ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(tab == 1 ? Color.ink : Color.ink.opacity(0.66))
        }
        .frame(width: 104)
        .contentShape(Rectangle())
        .onTapGesture { if on { picked.remove(f.id) } else { picked.insert(f.id) } }
    }

    private func stat(_ title: String, _ items: [PhoneFile], _ color: Color) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(title).font(.system(size: 11, weight: .semibold)) }
                    .foregroundStyle(Color.ink.opacity(0.8))
                Text("\(items.count)").font(.system(size: 20, weight: .light)).monospacedDigit()
                Text(FS.fmt(items.reduce(0) { $0 + $1.size })).font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.74))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { tab = i } } label: {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(tab == i ? Color.ink : Color.ink.opacity(0.06)))
                .foregroundStyle(tab == i ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }
}
