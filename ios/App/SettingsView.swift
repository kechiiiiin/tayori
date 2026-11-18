import SwiftUI

/// 接続の設定。ふだんはアーカイブに埋め込んだサービストークンで動くので触らない。上書きしたいときだけ貼る
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let firstRun: Bool
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saved = false

    var body: some View {
        Form {
            if firstRun {
                Section {
                    Text("便りの Worker につなぐサービストークンが入っていません。TestFlight のビルドには埋め込まれています。手で入れるときは下に貼ってください。")
                        .font(.footnote)
                }
            }
            Section("つなぎ先") {
                Text(ServerConfig.baseURL?.absoluteString ?? "（未設定）").font(.footnote.monospaced())
                if let hint = AccessTokenStore.hint {
                    LabeledContent("Client ID", value: hint)
                } else {
                    Text("サービストークン: なし").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("サービストークンを上書きする") {
                SecureField("CF-Access-Client-Id", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("CF-Access-Client-Secret", text: $clientSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存") { save() }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved { Text("保存しました").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("接続の設定")
    }

    private func save() {
        try? AccessTokenStore.clientID.save(clientID.trimmingCharacters(in: .whitespacesAndNewlines))
        try? AccessTokenStore.clientSecret.save(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        clientID = ""
        clientSecret = ""
        saved = true
        model.refreshConfigured()
        Task { await model.reload() }
    }
}
