import SwiftUI

// MARK: - Status

extension SyncState {
    var color: Color {
        switch self {
        case .localOnly: return .gray
        case .connecting: return .yellow
        case .synced: return .green
        case .offline: return .red
        }
    }
}

/// A coloured dot and one word: "Synced", "Offline", "Local only", "Connecting…".
struct SyncStatusView: View {
    @EnvironmentObject var store: BookingStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.syncState.color)
                .frame(width: 8, height: 8)
            Text(store.syncState.label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync: \(store.syncState.label)")
        .accessibilityHint(store.syncError ?? "")
    }
}

// MARK: - Settings

/// Where the laundry server is. Present as a sheet:
/// `.sheet(isPresented: $showServer) { ServerSettingsView().environmentObject(store) }`
struct ServerSettingsView: View {
    @EnvironmentObject var store: BookingStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var token = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var config: ServerConfig? { ServerConfig(urlText: urlText, token: token) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("http://192.168.0.10:8080", text: $urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("Token (if the server has one)", text: $token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("Laundry server")
                } footer: {
                    Text("Every iPad pointed at the same server shares one set of bookings. Leave it empty to keep bookings on this iPad only.")
                }

                Section {
                    Button(action: test) {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(config == nil || testing)
                    if let result = testResult {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.ok ? .green : .orange)
                    }
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        SyncStatusView()
                    }
                    if let error = store.syncError {
                        Text(error).font(.footnote).foregroundColor(.secondary)
                    }
                }

                if store.serverConfig != nil {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            store.useServer(nil)
                            dismiss()
                        }
                    } footer: {
                        Text("This iPad goes back to its own bookings. Nothing is deleted from the server.")
                    }
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.useServer(config)
                        dismiss()
                    }
                    .disabled(!urlText.trimmingCharacters(in: .whitespaces).isEmpty && config == nil)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            urlText = store.serverConfig?.baseURL.absoluteString
                ?? UserDefaults.standard.string(forKey: ServerConfig.urlKey) ?? ""
            token = store.serverConfig?.token ?? UserDefaults.standard.string(forKey: ServerConfig.tokenKey) ?? ""
        }
    }

    private func test() {
        guard let config = config else { return }
        testing = true
        testResult = nil
        Task { @MainActor in
            let client = APIClient(config: config)
            do {
                _ = try await client.health()
                // /health needs no token; /version checks it.
                let version = try await client.version()
                testResult = (true, "Connected (server version \(version)).")
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}

// MARK: - Notifications

/// "Your slot moved" messages from the server for one person, with
/// mark-as-read. Present as a sheet or popover:
/// `NotificationsView(person: form.person).environmentObject(store)`
struct NotificationsView: View {
    @EnvironmentObject var store: BookingStore
    @Environment(\.dismiss) private var dismiss

    @State var person: Person?
    @State private var items: [ServerNotification] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Person", selection: $person) {
                        ForEach(Person.allCases) { p in
                            Text(p.name).tag(Optional(p))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                content
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Mark All Read") { markAllRead() }
                        .disabled(!items.contains { $0.readAt == nil })
                }
            }
        }
        .navigationViewStyle(.stack)
        .task(id: person) { await load() }
        .onChange(of: store.bookings) { _ in Task { await load() } }
    }

    @ViewBuilder private var content: some View {
        if store.sync == nil {
            Text("Connect this iPad to a laundry server to get notifications.")
                .foregroundColor(.secondary)
        } else if person == nil {
            Text("Choose whose notifications to show.").foregroundColor(.secondary)
        } else if let error = error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
        } else if items.isEmpty {
            Text(loading ? "Loading…" : "Nothing new.").foregroundColor(.secondary)
        } else {
            Section {
                ForEach(items) { item in
                    row(item)
                        .swipeActions {
                            if item.readAt == nil {
                                Button("Mark Read") { markRead(item) }.tint(.blue)
                            }
                        }
                }
            }
        }
    }

    private func row(_ item: ServerNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.readAt == nil ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.message)
                    .fontWeight(item.readAt == nil ? .semibold : .regular)
                Text(item.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
                + Text(" ago").font(.caption).foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if item.readAt == nil { markRead(item) } }
    }

    @MainActor private func load() async {
        guard let client = store.sync?.client, let person = person else { items = []; return }
        loading = true
        defer { loading = false }
        do {
            items = try await client.notifications(for: person)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markRead(_ item: ServerNotification) {
        guard let client = store.sync?.client else { return }
        if let i = items.firstIndex(of: item) { items[i].readAt = Date() }
        Task { @MainActor in
            do { try await client.markRead(item.id) } catch { await load() }
        }
    }

    private func markAllRead() {
        for item in items where item.readAt == nil { markRead(item) }
    }
}
