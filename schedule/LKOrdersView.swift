import SwiftUI

// MARK: - Приказы

struct LKOrdersView: View {
    @ObservedObject var manager = LKManager.shared
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        SwiftUI.Group {
            if isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Загрузка приказов...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if manager.orders.isEmpty && !hasLoaded {
                VStack(spacing: 16) {
                    Spacer()
                    Button {
                        loadOrders()
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.richtext.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("Загрузить приказы")
                                .font(.headline)
                                .foregroundStyle(.blue)
                        }
                    }
                    Spacer()
                }
            } else if manager.orders.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Приказы не найдены")
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ordersList
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Приказы")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if manager.orders.isEmpty {
                loadOrders()
            } else {
                hasLoaded = true
            }
        }
        .refreshable {
            await refreshOrders()
        }
    }

    // MARK: - Список приказов

    private var ordersList: some View {
        List {
            ForEach(manager.orders) { order in
                OrderRowView(order: order)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
    }

    // MARK: - Загрузка

    private func loadOrders() {
        isLoading = true
        Task {
            manager.orders = await manager.fetchOrders()
            hasLoaded = true
            isLoading = false
        }
    }

    private func refreshOrders() async {
        manager.orders = await manager.fetchOrders()
        hasLoaded = true
    }
}

// MARK: - Строка приказа

struct OrderRowView: View {
    let order: Order
    @State private var copied = false
    @AppStorage("accentColor") private var accentRaw = "faTeal"
    private var accent: Color { AccentColors.color(accentRaw) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Левая колонка: номер приказа (крупно, акцентный цвет)
            VStack(spacing: 4) {
                if !order.displayNumber.isEmpty {
                    Text(order.displayNumber)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(accent)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(minWidth: 50)
                } else {
                    Image(systemName: "number")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 50)
                }
                Spacer(minLength: 4)
                if let dateStr = order.formattedDate {
                    Text(String(dateStr.prefix(5)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 60)

            // Правая колонка: название + дата вступления в силу
            VStack(alignment: .leading, spacing: 6) {
                Text(order.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // Дата вступления в силу
                if let approveDate = order.formattedApproveDate {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Вступает в силу: \(approveDate)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                copyOrderInfo()
            } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            }
        }
        .overlay(alignment: .topTrailing) {
            if copied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                    .transition(.scale)
            }
        }
    }

    private func copyOrderInfo() {
        var text = ""
        if !order.displayNumber.isEmpty { text += "\(order.displayNumber)\n" }
        text += order.displayTitle
        if let date = order.formattedDate { text += "\nДата: \(date)" }
        if let approve = order.formattedApproveDate { text += "\nВступает в силу: \(approve)" }

        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}
