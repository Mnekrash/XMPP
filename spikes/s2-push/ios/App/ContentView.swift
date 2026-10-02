import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var model: SpikeModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Server (staging)") {
                    TextField("host", text: $model.host).textInputAutocapitalization(.never)
                    TextField("JID", text: $model.jid).textInputAutocapitalization(.never)
                    SecureField("password", text: $model.password)
                    TextField("push gateway JID", text: $model.gatewayJid).textInputAutocapitalization(.never)
                }
                Section("Display names (jid=Name per line, shared with the NSE)") {
                    TextEditor(text: $model.namesText).frame(minHeight: 60).font(.footnote.monospaced())
                }
                Section("Status: \(model.status)") {
                    Button("Connect + enable push") { Task { await model.connect() } }
                    Button("Logout (cleanup)", role: .destructive) { Task { await model.logout() } }
                    Picker("NSE failure injection", selection: Binding(get: { model.nseMode }, set: { model.setNSEMode($0) })) {
                        Text("none").tag("none")
                        Text("timeout").tag("timeout")
                        Text("crash").tag("crash")
                    }
                }
                Section("Log") {
                    Button("Copy full log (app + NSE)") { UIPasteboard.general.string = SharedStore.readLog() }
                    ForEach(model.log.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("S2 Push Spike")
        }
    }
}
