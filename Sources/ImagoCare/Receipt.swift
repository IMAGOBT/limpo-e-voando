import SwiftUI
import AppKit

// MARK: - Espaço real medido no disco

enum Disk {
    /// Espaço realmente livre agora (sem contar o "purgável" que o macOS promete liberar).
    static func free() -> Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
    }
}

struct Receipt: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let title: String
    let count: Int
    let estimated: Int64      // soma do tamanho dos itens
    let real: Int64           // diferença medida no disco (depois − antes)
    let trashed: Int64        // ainda ocupando espaço na Lixeira
}

extension AppState {
    static let receiptsKey = "receipts.v1"

    static func loadReceipts() -> [Receipt] {
        (UserDefaults.standard.data(forKey: receiptsKey)).flatMap { try? JSONDecoder().decode([Receipt].self, from: $0) } ?? []
    }

    /// Mede o disco antes e depois de uma ação, guarda o recibo e mostra o resultado real.
    @discardableResult
    func measured(_ title: String, settle: Double = 2, _ work: () async -> CleanResult) async -> CleanResult {
        let before = Disk.free()
        let r = await work()
        // o APFS leva um instante para devolver o espaço
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        var real = max(0, Disk.free() - before)
        if r.freed > 0 { real = min(real, r.freed) }   // outras atividades do Mac não entram na conta
        guard r.count > 0 || real > 0 else {
            if !r.failures.isEmpty { toast = "\(r.failures.count) itens não puderam ser removidos" }
            return r
        }
        let receipt = Receipt(date: Date(), title: title, count: r.count, estimated: r.freed, real: real, trashed: r.trashed)
        receipts.insert(receipt, at: 0)
        if receipts.count > 300 { receipts.removeLast(receipts.count - 300) }
        if let d = try? JSONEncoder().encode(Array(receipts.prefix(300))) { UserDefaults.standard.set(d, forKey: Self.receiptsKey) }
        lastReceipt = receipt

        // o total do app passa a ser só o que foi medido de verdade
        freedTotal += real
        cleanCount += 1
        lastClean = Date()
        UserDefaults.standard.set(Double(freedTotal), forKey: "freedTotal")
        UserDefaults.standard.set(cleanCount, forKey: "cleanCount")
        UserDefaults.standard.set(lastClean, forKey: "lastClean")
        if !r.failures.isEmpty { toast = "\(r.failures.count) itens não puderam ser removidos" }
        return r
    }

    var trashPending: Int64 { receipts.prefix(20).reduce(0) { $0 + $1.trashed } }

    func emptyTrashMeasured() async {
        await measured("Lixeira esvaziada", settle: 3) {
            let before = Disk.free()
            let err = await Task.detached { Extras.emptyTrash() }.value
            if let err { toast = "Não consegui esvaziar: \(err)"; return CleanResult() }
            // zera o "na Lixeira" dos recibos anteriores
            receipts = receipts.map { Receipt(id: $0.id, date: $0.date, title: $0.title, count: $0.count,
                                              estimated: $0.estimated, real: $0.real, trashed: 0) }
            _ = before
            return CleanResult(count: 1, freed: 0)
        }
    }
}

// MARK: - Recibo na tela

struct ReceiptBanner: View {
    @EnvironmentObject var state: AppState
    @State private var confirmEmpty = false

    var body: some View {
        if let r = state.lastReceipt {
            let lowVsEstimate = r.trashed == 0 && r.estimated > 0 && Double(r.real) < Double(r.estimated) * 0.5
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIBERADO DE VERDADE").font(.system(size: 10, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Color.ink.opacity(0.74))
                    Text(FS.fmt(r.real)).font(.system(size: 30, weight: .light)).monospacedDigit()
                        .foregroundStyle(r.real > 0 ? Theme.green : Color.ink)
                    Text("medido no disco · \(r.title)").font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.76))
                }
                Rectangle().fill(Color.ink.opacity(0.12)).frame(width: 1, height: 58)
                VStack(alignment: .leading, spacing: 6) {
                    row("Estimado", FS.fmt(r.estimated), Color.ink.opacity(0.8))
                    row("Itens", "\(r.count)", Color.ink.opacity(0.8))
                    if r.trashed > 0 {
                        row("Na Lixeira", FS.fmt(r.trashed), Theme.orange)
                    }
                }
                .frame(width: 170)
                VStack(alignment: .leading, spacing: 8) {
                    if r.trashed > 0 {
                        Text("Itens na Lixeira ainda ocupam espaço. Ele volta quando a Lixeira for esvaziada.")
                            .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                        PillButton(title: "Esvaziar Lixeira", icon: "trash") { confirmEmpty = true }
                    } else if lowVsEstimate {
                        Text("O macOS pode levar alguns minutos para devolver o espaço, ou capturas do Time Machine ainda guardam esses dados.")
                            .font(.system(size: 12)).foregroundStyle(Theme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("O número acima é a diferença real de espaço livre, antes e depois.", systemImage: "checkmark.seal")
                            .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.75))
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)
                Button { withAnimation { state.lastReceipt = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.74))
            }
            .padding(18)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: r.id) {
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                withAnimation { if state.lastReceipt?.id == r.id && !confirmEmpty { state.lastReceipt = nil } }
            }
            .confirmationDialog("Esvaziar a Lixeira?", isPresented: $confirmEmpty) {
                Button("Esvaziar", role: .destructive) { Task { await state.emptyTrashMeasured() } }
            } message: {
                Text("Tudo que está na Lixeira será apagado para sempre. O macOS pode pedir permissão para o app controlar o Finder.")
            }
        }
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
    }
}
