//
//  WebSearchSettingsView.swift
//  fullmoon
//
//  Created by Codex on 2/5/26.
//

import SwiftUI

struct WebSearchSettingsView: View {
    @EnvironmentObject var appManager: AppManager

    private var trimmedAPIKey: String {
        appManager.exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                Toggle("enable web search", isOn: $appManager.webSearchEnabled)
            } footer: {
                Text("when enabled, cloud models can call web search for up-to-date information")
                    .font(.caption)
            }

            Section(header: Text("EXA API key")) {
                SecureField("api key", text: $appManager.exaAPIKey)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                if appManager.webSearchEnabled && trimmedAPIKey.isEmpty {
                    Text("add an EXA API key to use web search")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("web search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    WebSearchSettingsView()
        .environmentObject(AppManager())
}
