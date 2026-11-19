import SwiftUI
import GroshiCore

struct TransactionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let txID: UUID
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let tx = store.data.transactions.first(where: { $0.id == txID }) {
                    content(tx)
                } else {
                    ContentUnavailableView(L("Операция удалена"), systemImage: "trash")
                }
            }
            .background(Palette.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    AssistantToolbarButton(context: contextText)
                }
            }
            .sheet(isPresented: $editing) {
                if let tx = store.data.transactions.first(where: { $0.id == txID }) { AddTransactionView(editing: tx) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    var contextText: String? {
        guard let tx = store.data.transactions.first(where: { $0.id == txID }) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return "The user is looking at transaction id \(String(tx.id.uuidString.prefix(8)).lowercased()): \(tx.kind.rawValue) \(MoneyMath.plainString(tx.amountMinor, currency: tx.currency)) \(tx.currency), category \(store.data.category(tx.categoryID)?.name ?? "?"), \(f.string(from: tx.date)). 'This operation' refers to it."
    }

    func content(_ tx: Txn) -> some View {
        let cat = store.data.category(tx.categoryID)
        let wallet = store.data.wallet(tx.walletID)
        return ScrollView {
            VStack(spacing: 18) {
                Group {
                    if tx.isTransfer { TransferIcon(size: 72) } else { CategoryIconView(category: cat, size: 72) }
                }
                .padding(.top, 8)
                Text(Fmt.signed(tx))
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.amount(tx.kind))
                Text(tx.isTransfer ? Fmt.route(tx, store.data) : (cat?.name ?? "—")).font(.headline)

                Card {
                    VStack(spacing: 12) {
                        row(L("Тип"), tx.kind == .expense ? L("Расход") : (tx.kind == .income ? L("Доход") : L("Перевод")))
                        Divider()
                        if tx.isTransfer {
                            row(L("Откуда"), wallet.map { "\($0.name) · \($0.currency)" } ?? "—")
                            Divider()
                            row(L("Куда"), tx.toWalletID.flatMap { store.data.wallet($0) }.map { "\($0.name) · \($0.currency)" } ?? "—")
                            if tx.creditedCurrency != tx.currency {
                                Divider()
                                row(L("Зачислено"), Fmt.money(tx.creditedMinor, tx.creditedCurrency))
                            }
                        } else {
                            row(L("Кошелёк"), wallet.map { "\($0.name) · \($0.currency)" } ?? "—")
                        }
                        Divider()
                        row(L("Дата"), Fmt.fullDate(tx.date))
                        if tx.currency != store.data.settings.baseCurrency,
                           let c = store.data.settings.converter.convert(tx.amountMinor, from: tx.currency, to: store.data.settings.baseCurrency) {
                            Divider()
                            row(L("В основной валюте"), "≈ " + Fmt.money(c, store.data.settings.baseCurrency))
                        }
                        if !tx.note.isEmpty {
                            Divider()
                            row(L("Комментарий"), tx.note)
                        }
                        Divider()
                        row(L("Источник"), tx.source == .ai ? L("AI-ассистент") : (tx.source == .imported ? L("Импорт") : L("Вручную")))
                    }
                }

                HStack(spacing: 12) {
                    Button { editing = true } label: {
                        Label(L("Изменить"), systemImage: "pencil").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-edit")
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(L("Удалить"), systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-delete")
                }
                .controlSize(.large)
            }
            .padding(16)
        }
        .confirmationDialog(L("Удалить операцию?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                if store.perform(.deleteTransactions([tx.id]), label: L("Операция удалена")) { dismiss() }
            }
        }
    }

    func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
