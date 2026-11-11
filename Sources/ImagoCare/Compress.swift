import SwiftUI
import AppKit
import AVFoundation
import PDFKit

// MARK: - Modelos

enum CompressKind: Sendable { case video, pdf, audio }

struct CompressItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let kind: CompressKind
    var info: String = ""
    var estimate: Int64? = nil        // tamanho estimado depois de comprimir
    var alreadyEfficient = false      // já está em HEVC
    var inCloud = false
}

enum CompressStatus: Equatable, Sendable {
    case waiting, working(Double), uploading, done(saved: Int64), skipped(String), failed(String)
    case converted(String)
}

struct CompressJob: Identifiable, Sendable {
    let id = UUID()
    let item: CompressItem
    var status: CompressStatus = .waiting
}

// MARK: - Motor

enum CompressEngine {
    static let videoExt: Set<String> = ["mov", "mp4", "m4v"]

    /// Vídeos ≥ 150 MB e PDFs ≥ 8 MB nas pastas locais do usuário.
    static func scan() async -> [CompressItem] {
        let home = FS.home
        let roots = ["Downloads", "Desktop", "Documents", "Movies"].map { home.appendingPathComponent($0) }
        let found: [(URL, Int64)] = await Task.detached {
            var out: [(URL, Int64)] = []
            for root in roots {
                FS.walkFiles(root) { url, size, _ in
                    let ext = url.pathExtension.lowercased()
                    if (videoExt.contains(ext) && size >= 150 * 1024 * 1024) || (ext == "pdf" && size >= 8 * 1024 * 1024) {
                        if !CloudEngine.isCloud(url) { out.append((url, size)) }
                    }
                }
            }
            return out
        }.value
        var items: [CompressItem] = []
        for (url, size) in found { items.append(await describe(url, size: size)) }
        return items.sorted { ($0.size - ($0.estimate ?? $0.size)) > ($1.size - ($1.estimate ?? $1.size)) }
    }

    static func describe(_ url: URL, size: Int64) async -> CompressItem {
        let cloud = CloudEngine.isCloud(url)
        if url.pathExtension.lowercased() == "pdf" {
            let pages = PDFDocument(url: url)?.pageCount ?? 0
            return CompressItem(url: url, size: size, kind: .pdf,
                                info: pages > 0 ? "PDF · \(pages) páginas" : "PDF",
                                estimate: Int64(Double(size) * 0.45), inCloud: cloud)
        }
        var item = CompressItem(url: url, size: size, kind: .video, info: "Vídeo", inCloud: cloud)
        // arquivos só na nuvem não são lidos aqui (evita baixar só para descrever)
        if cloud, (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0 == 0 {
            item.info = "Vídeo na nuvem"
            item.estimate = Int64(Double(size) * 0.5)
            return item
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, formats) = try? await track.load(.naturalSize, .formatDescriptions),
              let duration = try? await asset.load(.duration) else { return item }
        let raw = CMTimeGetSeconds(duration)
        let secs = raw.isFinite ? max(raw, 1) : 1      // duração inválida (vídeo gravando/corrompido) não derruba o app
        let h = Int(min(abs(natural.height), abs(natural.width)))
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let isHEVC = codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha
        let codecName: String = {
            switch codec {
            case kCMVideoCodecType_H264: return "H.264"
            case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
            case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
                 kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes4444: return "ProRes"
            default: return "vídeo"
            }
        }()
        let mins = Int(secs) / 60, rest = Int(secs) % 60
        item.info = "\(Int(abs(natural.width)))×\(Int(abs(natural.height))) · \(codecName) · \(mins)min\(String(format: "%02d", rest))s"
        // taxa típica de HEVC em alta qualidade por resolução (Mbps)
        let target: Double = h >= 2000 ? 24 : h >= 1400 ? 15 : h >= 1000 ? 9 : h >= 700 ? 5 : 2.5
        let est = Int64(target * 1_000_000 / 8 * secs)
        item.estimate = min(size, est)
        item.alreadyEfficient = isHEVC
        return item
    }

    // Vídeo → HEVC
    static func compressVideo(_ src: URL, to dst: URL, smaller: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async -> String? {
        let asset = AVURLAsset(url: src)
        let preset = smaller ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            return "Formato não suportado pelo codificador do Mac"
        }
        session.outputURL = dst
        session.outputFileType = src.pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = true
        let poll = Task.detached {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        await session.export()
        poll.cancel()
        if session.status == .completed { return nil }
        return session.error?.localizedDescription ?? "A conversão falhou"
    }

    // PDF → imagens recomprimidas
    static func compressPDF(_ src: URL, to dst: URL) -> String? {
        guard let doc = PDFDocument(url: src) else { return "Não consegui abrir o PDF" }
        if doc.isEncrypted && doc.isLocked { return "PDF protegido por senha" }
        let ok = doc.write(to: dst, withOptions: [.saveImagesAsJPEGOption: true,
                                                  .optimizeImagesForScreenOption: true])
        return ok ? nil : "Não consegui salvar o PDF comprimido"
    }

    /// Troca o original pelo comprimido conforme a escolha do usuário.
    /// - original: 0 = Lixeira, 1 = apagar de vez, 2 = manter e salvar cópia ao lado
    static func finalize(src: URL, tmp: URL, original: Int) -> (saved: Int64, final: URL?, skip: String?) {
        let old = (try? FS.fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 0
        let new = (try? FS.fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard new > 0, Double(new) < Double(old) * 0.9 else {
            try? FS.fm.removeItem(at: tmp)
            return (0, nil, "Não compensou: já estava otimizado")
        }
        // preserva as datas do original
        if let attrs = try? FS.fm.attributesOfItem(atPath: src.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
            if let c = attrs[.creationDate] { keep[.creationDate] = c }
            try? FS.fm.setAttributes(keep, ofItemAtPath: tmp.path)
        }
        do {
            if original == 2 {
                let base = src.deletingPathExtension().lastPathComponent
                var dst = src.deletingLastPathComponent().appendingPathComponent("\(base) (comprimido).\(src.pathExtension)")
                var i = 2
                while FS.fm.fileExists(atPath: dst.path) {
                    dst = src.deletingLastPathComponent().appendingPathComponent("\(base) (comprimido \(i)).\(src.pathExtension)")
                    i += 1
                }
                try FS.fm.moveItem(at: tmp, to: dst)
                return (0, dst, nil)
            }
            if original == 0 {
                // guarda uma cópia do original na Lixeira antes da troca
                let keep = src.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(src.pathExtension)")
                try FS.fm.copyItem(at: src, to: keep)
                try FS.fm.trashItem(at: keep, resultingItemURL: nil)
            }
            // troca atômica: se falhar, o original continua intacto
            _ = try FS.fm.replaceItemAt(src, withItemAt: tmp)
            return (old - new, src, nil)
        } catch {
            try? FS.fm.removeItem(at: tmp)
            return (0, nil, "Erro ao trocar o arquivo: \(error.localizedDescription)")
        }
    }

    static func freeSpace() -> Int64 {
        Int64((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - Áudio → MP3

enum AudioConvert {
    static let inputExt: Set<String> = ["opus", "ogg", "oga", "mp4", "m4v", "mov", "m4a", "aac", "wav", "aif", "aiff",
                                        "flac", "webm", "mkv", "caf", "wma", "amr", "3gp", "mp3"]

    /// ffmpeg instalado (Homebrew). Sem ele, o macOS não grava MP3 — usamos M4A.
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func outputURL(for src: URL, ext: String) -> URL {
        let dir = src.deletingLastPathComponent(), base = src.deletingPathExtension().lastPathComponent
        var u = dir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(base) (\(i)).\(ext)")
            i += 1
        }
        return u
    }

    /// Converte para MP3 (ffmpeg) ou M4A (nativo). Retorna o arquivo criado ou o erro.
    static func convert(_ src: URL, quality: Int) async -> (URL?, String?) {
        if let ff = ffmpeg {
            let dst = outputURL(for: src, ext: "mp3")
            let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp3")
            let q: [String] = quality == 0 ? ["-q:a", "0"] : quality == 1 ? ["-q:a", "2"] : ["-b:a", "128k"]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ff)
            p.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", src.path,
                           "-vn", "-map_metadata", "0", "-c:a", "libmp3lame"] + q + [tmp.path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return (nil, "Não consegui abrir o ffmpeg") }
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp.path) else {
                try? FileManager.default.removeItem(at: tmp)
                return (nil, msg.split(separator: "\n").last.map(String.init) ?? "A conversão falhou")
            }
            do { try FileManager.default.moveItem(at: tmp, to: dst) } catch { return (nil, error.localizedDescription) }
            return (dst, nil)
        }
        // sem ffmpeg: M4A (AAC) nativo da Apple
        let dst = outputURL(for: src, ext: "m4a")
        guard let s = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetAppleM4A) else {
            return (nil, "Formato não suportado")
        }
        s.outputURL = dst
        s.outputFileType = .m4a
        await s.export()
        return s.status == .completed ? (dst, nil) : (nil, s.error?.localizedDescription ?? "A conversão falhou")
    }

    static func describe(_ url: URL) async -> CompressItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var info = url.pathExtension.uppercased()
        if let d = try? await AVURLAsset(url: url).load(.duration), d.seconds.isFinite, d.seconds > 0 {
            let s = Int(d.seconds); info += " · \(s / 60)min\(String(format: "%02d", s % 60))s"
        }
        return CompressItem(url: url, size: size, kind: .audio, info: info)
    }
}

// MARK: - Estado

extension AppState {
    var selectedCompress: [CompressItem] { compressItems.filter { selected.contains($0.url) } }
    var compressActive: Bool { compressJobs.contains { if case .working = $0.status { return true }; return $0.status == .waiting || $0.status == .uploading } }

    func addToCompress(_ urls: [URL]) async {
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard CompressEngine.videoExt.contains(ext) || ext == "pdf" else {
                toast = "\(u.lastPathComponent): só vídeos .mov/.mp4/.m4v e PDFs."
                continue
            }
            guard !compressItems.contains(where: { $0.url == u }) else { continue }
            let size = (try? FS.fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
            let item = await CompressEngine.describe(u, size: size)
            compressItems.insert(item, at: 0)
            selected.insert(u)
        }
    }

    func addAudio(_ urls: [URL]) async {
        for u in urls {
            guard AudioConvert.inputExt.contains(u.pathExtension.lowercased()) else {
                toast = "\(u.lastPathComponent): formato de áudio/vídeo não reconhecido."
                continue
            }
            guard !audioItems.contains(where: { $0.url == u }) else { continue }
            audioItems.insert(await AudioConvert.describe(u), at: 0)
            selected.insert(u)
        }
    }

    func runAudioConversion(_ items: [CompressItem]) async {
        let q = mp3Quality
        let jobs = items.map { CompressJob(item: $0) }
        compressJobs.insert(contentsOf: jobs, at: 0)
        items.forEach { selected.remove($0.url) }
        var ok = 0
        for job in jobs {
            guard let i = compressJobs.firstIndex(where: { $0.id == job.id }) else { continue }
            compressJobs[i].status = .working(0.5)
            let (out, err) = await AudioConvert.convert(job.item.url, quality: q)
            guard let k = compressJobs.firstIndex(where: { $0.id == job.id }) else { continue }
            if let out {
                compressJobs[k].status = .converted("\(out.lastPathComponent) salvo ao lado")
                ok += 1
            } else {
                compressJobs[k].status = .failed(err ?? "A conversão falhou")
            }
        }
        let done = Set(compressJobs.filter { j in jobs.contains { $0.id == j.id } && { if case .converted = j.status { return true }; return false }() }.map(\.item.url))
        audioItems.removeAll { done.contains($0.url) }
        toast = "\(ok) de \(jobs.count) convertidos para \(AudioConvert.ffmpeg == nil ? "M4A" : "MP3") · o original foi mantido"
    }

    func runCompression(_ items: [CompressItem]) async {
        await measured("Compressor", settle: 3) { await compressLoop(items) }
    }

    private func compressLoop(_ items: [CompressItem]) async -> CleanResult {
        var trashedBytes: Int64 = 0
        let smaller = compressQuality == 1
        let original = compressOriginal
        let newJobs = items.map { CompressJob(item: $0) }
        compressJobs.insert(contentsOf: newJobs, at: 0)
        items.forEach { selected.remove($0.url) }

        var totalSaved: Int64 = 0
        for job in newJobs {
            guard let idx = compressJobs.firstIndex(where: { $0.id == job.id }) else { continue }
            let item = job.item
            // arquivo na nuvem precisa de espaço para baixar + gerar a versão nova
            if item.inCloud && CompressEngine.freeSpace() < Int64(Double(item.size) * 1.6) {
                compressJobs[idx].status = .failed("Pouco espaço livre para baixar e comprimir este arquivo")
                continue
            }
            if original == 1 && item.info.contains("ProRes") {
                compressJobs[idx].status = .skipped("Master ProRes: por segurança não apago de vez — use Lixeira ou Manter cópia")
                continue
            }
            compressJobs[idx].status = .working(0)
            let tmp = item.url.deletingLastPathComponent()
                .appendingPathComponent(".\(item.url.deletingPathExtension().lastPathComponent).limpoevoando.\(item.url.pathExtension)")
            try? FS.fm.removeItem(at: tmp)
            let jobID = job.id
            let err: String?
            if item.kind == .video {
                err = await CompressEngine.compressVideo(item.url, to: tmp, smaller: smaller) { p in
                    Task { @MainActor in
                        if let i = self.compressJobs.firstIndex(where: { $0.id == jobID }), case .working = self.compressJobs[i].status {
                            self.compressJobs[i].status = .working(p)
                        }
                    }
                }
            } else {
                err = await Task.detached { CompressEngine.compressPDF(item.url, to: tmp) }.value
            }
            guard let i = compressJobs.firstIndex(where: { $0.id == jobID }) else { continue }
            if let err { try? FS.fm.removeItem(at: tmp); compressJobs[i].status = .failed(err); continue }

            let r = await Task.detached { CompressEngine.finalize(src: item.url, tmp: tmp, original: original) }.value
            if let skip = r.skip { compressJobs[i].status = .skipped(skip); continue }

            // no Drive: espera subir a versão leve e libera a cópia local
            if item.inCloud, let final = r.final {
                compressJobs[i].status = .uploading
                let deadline = Date().addingTimeInterval(2 * 3600)
                var confirmed = false
                while Date() < deadline {
                    let st = await Task.detached { CloudEngine.uploadState(final) }.value
                    if st.done { confirmed = true; break }
                    if st.error != nil { break }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                if confirmed { await Task.detached { CloudEngine.evict(final) }.value }
            }
            compressJobs[i].status = .done(saved: r.saved)
            totalSaved += r.saved
            if original == 0 && r.saved > 0 { trashedBytes += item.size }
            compressItems.removeAll { $0.url == item.url && original != 2 }
        }
        return CleanResult(count: newJobs.count, freed: totalSaved, trashed: trashedBytes)
    }
}

// MARK: - Tela

struct CompressView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0
    @State private var confirm = false
    @State private var confirmAudio = false

    // Sem tela de abertura: a pessoa escolhe na hora — o app encontra os pesados ou ela envia os seus.
    var body: some View { results }

    private var list: [CompressItem] {
        tab == 2 ? state.audioItems : state.compressItems.filter { tab == 0 ? $0.kind == .video : $0.kind == .pdf }
    }
    private var selectedSize: Int64 { state.selectedCompress.reduce(0) { $0 + $1.size } }
    private var selectedSaving: Int64 { state.selectedCompress.reduce(0) { $0 + ($1.size - ($1.estimate ?? $1.size)) } }
    private var selectedAudio: [CompressItem] { state.audioItems.filter { state.selected.contains($0.url) } }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(Section.compress.number).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Rectangle().fill(Color.ink.opacity(0.4)).frame(width: 22, height: 0.8)
                Text("COMPRESSOR").font(.system(size: 11, weight: .semibold)).tracking(2.2)
                Spacer()
                HStack(spacing: 4) {
                    tabButton("Vídeos · \(state.compressItems.filter { $0.kind == .video }.count)", 0)
                    tabButton("PDFs · \(state.compressItems.filter { $0.kind == .pdf }.count)", 1)
                    tabButton("Áudio → MP3 · \(state.audioItems.count)", 2)
                }
                .padding(4).background(Capsule().fill(Color.ink.opacity(0.07)))
            }
            .foregroundStyle(Color.ink.opacity(0.74))
            .padding(.top, 26)

            Text(tab == 2 ? "Converta áudio e vídeo para MP3" : "Deixe vídeos e PDFs mais leves")
                .font(.system(size: 30, weight: .light))

            // De onde vêm os arquivos: o app encontra ou a pessoa envia
            HStack(spacing: 12) {
                if tab != 2 {
                    sourceButton("Encontrar os pesados no Mac", "magnifyingglass",
                                 state.busy == .compress ? "Procurando…" : (state.scanned.contains(.compress) ? "Procurar de novo" : "Vídeos acima de 150 MB e PDFs acima de 8 MB")) {
                        Task { await state.scan(.compress) }
                    }
                    .disabled(state.busy != nil)
                }
                sourceButton("Escolher meus arquivos", "plus.rectangle.on.folder",
                             tab == 2 ? "Opus, MP4, MOV, M4A, WAV… (ou arraste aqui)" : "Do Mac ou do Google Drive (ou arraste aqui)") { pickFiles() }
            }

            // Opções
            HStack(spacing: 14) {
                if tab == 2 {
                    option("Qualidade", ["Alta (~245 kbps)", "Padrão (~190 kbps)", "Leve (128 kbps)"], $state.mp3Quality)
                    if AudioConvert.ffmpeg == nil {
                        Label("Sem ffmpeg: o app converte para M4A. Para MP3, instale o ffmpeg (brew install ffmpeg).",
                              systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.orange)
                    } else {
                        Label("O original é mantido; o MP3 é salvo ao lado.", systemImage: "checkmark.shield")
                            .font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.74))
                    }
                } else {
                    option("Vídeo", ["Alta qualidade", "Menor tamanho (1080p)"], $state.compressQuality)
                    option("Original", ["Vai para a Lixeira", "Apagar de vez", "Manter e salvar cópia"], $state.compressOriginal)
                }
                Spacer()
            }

            if !state.compressJobs.isEmpty { jobsPanel }

            GlassCard(padding: 12) {
                if state.busy == .compress && tab != 2 {
                    VStack(spacing: 14) {
                        LiveScanProgress(meter: state.meter, phase: state.phase)
                        Text("Lendo resolução, codec e duração de cada vídeo — pode levar 1 ou 2 minutos. Enquanto isso, você pode escolher seus arquivos.")
                            .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.74)).multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if list.isEmpty {
                    VStack(spacing: 10) {
                        IconTile(symbol: tab == 2 ? "waveform" : (tab == 0 ? "film" : "doc.richtext"), size: 40)
                        Text(emptyText).foregroundStyle(Color.ink.opacity(0.76)).multilineTextAlignment(.center)
                    }
                    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { row($0); Divider().overlay(Color.ink.opacity(0.07)) }
                        }
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                let audioTab = tab == 2
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            if audioTab { await state.addAudio([url]) } else { await state.addToCompress([url]) }
                        }
                    }
                }
                return true
            }

            if tab == 2 {
                ActionDock(section: .compress,
                           label: "Selecionado: \(selectedAudio.count) arquivo(s) · \(FS.fmt(selectedAudio.reduce(0) { $0 + $1.size }))",
                           button: "Converter", enabled: !selectedAudio.isEmpty && !state.compressActive) { confirmAudio = true }
            } else {
                ActionDock(section: .compress,
                           label: "Selecionado: \(FS.fmt(selectedSize)) · economia estimada ~\(FS.fmt(selectedSaving))",
                           button: "Comprimir", enabled: !state.selectedCompress.isEmpty && !state.compressActive) { confirm = true }
            }
        }
        .confirmationDialog("Comprimir \(state.selectedCompress.count) arquivo(s)?", isPresented: $confirm) {
            Button("Comprimir") {
                let items = state.selectedCompress
                Task { await state.runCompression(items) }
            }
        } message: {
            Text(confirmText)
        }
        .confirmationDialog("Converter \(selectedAudio.count) arquivo(s) para \(AudioConvert.ffmpeg == nil ? "M4A" : "MP3")?", isPresented: $confirmAudio) {
            Button("Converter") {
                let items = selectedAudio
                Task { await state.runAudioConversion(items) }
            }
        } message: {
            Text("O arquivo original continua onde está. A versão em áudio é salva na mesma pasta, com o mesmo nome.")
        }
    }

    private var emptyText: String {
        switch tab {
        case 2: return "Arraste áudios ou vídeos aqui (Opus do WhatsApp, MP4, MOV, M4A…) ou use \"Escolher meus arquivos\"."
        case 0: return state.scanned.contains(.compress) ? "Nenhum vídeo pesado encontrado. Escolha os seus ou arraste aqui."
                                                         : "Encontre os vídeos pesados do Mac ou escolha os seus."
        default: return state.scanned.contains(.compress) ? "Nenhum PDF pesado encontrado. Escolha os seus ou arraste aqui."
                                                          : "Encontre os PDFs pesados do Mac ou escolha os seus."
        }
    }

    private func sourceButton(_ title: String, _ icon: String, _ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: icon, tint: Theme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(Color.ink.opacity(0.74)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.6))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.ink.opacity(0.14), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var confirmText: String {
        var t = "Vídeos viram HEVC (H.265); PDFs têm as imagens recomprimidas. Se o resultado não ficar pelo menos 10% menor, o original fica intocado. "
        switch state.compressOriginal {
        case 0: t += "O original vai para a Lixeira — esvazie a Lixeira para liberar o espaço. "
        case 1: t += "O original é APAGADO DE VEZ assim que a versão leve estiver pronta. "
        default: t += "O original fica; a versão leve é salva ao lado com \"(comprimido)\" no nome. "
        }
        t += "Vídeos usados em projetos do Premiere continuam no mesmo caminho. Pode levar alguns minutos por vídeo — deixe o app aberto."
        return t
    }

    private func row(_ item: CompressItem) -> some View {
        HStack(spacing: 12) {
            CheckBox(state: state.selected.contains(item.url) ? 1 : 0) { state.toggle(item.url) }
            Image(nsImage: IconCache.icon( item.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).lineLimit(1)
                    if item.inCloud { Image(systemName: "icloud").font(.caption).foregroundStyle(Theme.teal) }
                    if item.alreadyEfficient {
                        Text("JÁ É HEVC").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.ink.opacity(0.2)))
                    }
                }
                Text(item.info).font(.caption).foregroundStyle(Color.ink.opacity(0.74)).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(FS.fmt(item.size)).monospacedDigit()
                if let est = item.estimate, est < item.size, !item.alreadyEfficient {
                    Text("→ ~\(FS.fmt(est))").font(.caption).monospacedDigit().foregroundStyle(Theme.teal)
                }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.74)).help("Mostrar no Finder")
        }
        .padding(.vertical, 7)
    }

    private var jobsPanel: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Fila de compressão").font(.headline)
                    Spacer()
                    if state.compressActive {
                        Text("Deixe o app aberto até terminar").font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                    } else {
                        Button("Limpar lista") { state.compressJobs.removeAll() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                    }
                }
                ScrollView {
                    VStack(spacing: 8) { ForEach(state.compressJobs) { jobRow($0) } }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func jobRow(_ job: CompressJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.item.kind == .video ? "film" : job.item.kind == .audio ? "waveform" : "doc.richtext").frame(width: 20)
            Text(job.item.url.lastPathComponent).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
            switch job.status {
            case .waiting:
                Text("Na fila").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
            case .working(let p):
                ProgressView(value: p).tint(Theme.blue).frame(maxWidth: .infinity)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 36)
            case .uploading:
                ProgressView().controlSize(.small)
                Text("Enviando versão leve para a nuvem…").font(.caption).foregroundStyle(Section.cloud.accent)
            case .done(let saved):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                Text(saved > 0 ? "Pronto · −\(FS.fmt(saved))" : "Pronto · cópia salva ao lado").font(.caption).foregroundStyle(Theme.teal)
            case .converted(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text(text).font(.caption).foregroundStyle(Theme.green).lineLimit(1)
            case .skipped(let why):
                Image(systemName: "equal.circle").foregroundStyle(Color.ink.opacity(0.74))
                Text(why).font(.caption).foregroundStyle(Color.ink.opacity(0.76))
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text(e).font(.caption).foregroundStyle(Theme.red).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(FS.fmt(job.item.size)).font(.caption).monospacedDigit().foregroundStyle(Color.ink.opacity(0.74))
        }
    }

    private func option(_ label: String, _ choices: [String], _ binding: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.76))
            Picker("", selection: binding) {
                ForEach(choices.indices, id: \.self) { Text(choices[$0]).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.ink.opacity(0.07)))
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { tab = i } } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(tab == i ? Color.ink : Color.clear))
                .foregroundStyle(tab == i ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let audioTab = tab == 2
        panel.allowedContentTypes = audioTab ? [.audio, .movie, .audiovisualContent] : [.movie, .mpeg4Movie, .quickTimeMovie, .pdf]
        panel.prompt = audioTab ? "Converter" : "Adicionar"
        panel.message = audioTab ? "Escolha áudios ou vídeos para virar MP3 (Opus, MP4, MOV, M4A…)"
                                 : "Escolha vídeos (.mov, .mp4) ou PDFs — inclusive do Google Drive"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { if audioTab { await state.addAudio(urls) } else { await state.addToCompress(urls) } }
        }
    }
}
