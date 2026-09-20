import SwiftUI

// Where the device is.
//
// Typed in, because namchaind has no discovery — no mDNS, no Bonjour. The token is
// the one the operator put in the device's `namchaind.json` or `tcp_token_file`;
// the daemon refuses to start a listener without one and refuses one under sixteen
// characters, because three guesses per connection is only a bound if guessing is
// hopeless.

struct ConnectionSettingsView: View {
    @Environment(EngineSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = String(EngineSettings.defaultPort)
    @State private var token = ""
    @State private var keychainComplaint: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host") {
                        // `labelsHidden` plus an explicit prompt: a bare
                        // `TextField(title, text:)` inside a `LabeledContent` draws
                        // its title *beside* the value rather than as a placeholder,
                        // so the field ends up saying everything twice.
                        TextField("Host", text: $host, prompt: Text("studio.local"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            #endif
                    }
                    LabeledContent("Port") {
                        TextField("Port", text: $port,
                                  prompt: Text(String(EngineSettings.defaultPort)))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("The address of the machine running namchaind, and its tcp_port.")
                }

                Section {
                    SecureField("Token", text: $token, prompt: Text("Paste the device's token"))
                        .labelsHidden()
                } header: {
                    Text("Token")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !token.isEmpty && token.count < EngineSettings.minimumTokenLength {
                            Text("\(token.count) of \(EngineSettings.minimumTokenLength) characters. "
                                 + "The device refuses a shorter one.")
                                .foregroundStyle(.orange)
                        }
                        Text("The token is the one in the device's namchaind.json, or the first line "
                             + "of its tcp_token_file. The connection is not encrypted and the token "
                             + "travels in it: off a network you trust, tunnel it.")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let keychainComplaint {
                    Section {
                        Label(keychainComplaint, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if case .failed(let why) = session.connection {
                    Section {
                        Label(why, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { save(andConnect: true) }
                        .disabled(!proposed.isComplete)
                }
            }
            .onAppear {
                host = session.settings.host
                port = String(session.settings.port)
                token = session.settings.token
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private var proposed: EngineSettings {
        EngineSettings(host: host.trimmingCharacters(in: .whitespaces),
                       port: UInt16(port) ?? EngineSettings.defaultPort,
                       token: token)
    }

    private func save(andConnect connect: Bool) {
        let settings = proposed
        keychainComplaint = EngineSettingsStore.save(settings)
        session.settings = settings
        // A failed keychain write is worth saying, but it does not stop this
        // session working — it only means the token is gone on the next launch.
        guard connect else { return }
        Task { await session.connect() }
        dismiss()
    }
}
