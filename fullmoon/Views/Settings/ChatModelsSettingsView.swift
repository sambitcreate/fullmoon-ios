//
//  ChatModelsSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI

struct ChatModelsSettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @State private var isFetchingCloudModels = false
    @State private var cloudFetchError: String?
    @State private var showCloudModelPicker = false
    @State private var cloudModelSearchText = ""

    private var filteredCloudModels: [String] {
        let trimmedQuery = cloudModelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return appManager.cloudModels }
        return appManager.cloudModels.filter { $0.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private var selectedCloudModel: Binding<String> {
        Binding(
            get: { appManager.currentCloudModelName ?? appManager.cloudModels.first ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                appManager.currentCloudModelName = newValue
                appManager.currentModelSource = .cloud
                appManager.playHaptic()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Toggle(isOn: $appManager.thinkingModeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thinking")
                            Text("Adds the research harness to cloud prompts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle(isOn: $appManager.webSearchEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Search")
                            Text("Lets cloud models call Exa for citations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section(header: Text("cloud models")) {
                if appManager.cloudModels.isEmpty {
                    Button {
                        fetchCloudModels()
                    } label: {
                        Label("refresh cloud models", systemImage: "arrow.clockwise")
                    }
                    .disabled(isFetchingCloudModels || appManager.cloudAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isFetchingCloudModels {
                        ProgressView()
                    }

                    Text("No cloud models yet. Check your endpoint in Settings > Models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let cloudFetchError {
                        Text(cloudFetchError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if appManager.cloudModels.count > 10 {
                    Button {
                        showCloudModelPicker = true
                    } label: {
                        Label("select cloud model", systemImage: "chevron.up.chevron.down")
                    }

                    HStack {
                        Text("selected")
                        Spacer()
                        Text(appManager.currentCloudModelName ?? "none")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("cloud model", selection: selectedCloudModel) {
                        ForEach(appManager.cloudModels, id: \.self) { modelName in
                            Text(modelName)
                                .tag(modelName)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showCloudModelPicker) {
            NavigationStack {
                List {
                    ForEach(filteredCloudModels, id: \.self) { modelName in
                        Button {
                            selectCloudModel(modelName)
                            showCloudModelPicker = false
                        } label: {
                            HStack {
                                Text(modelName)
                                Spacer()
                                if appManager.currentCloudModelName == modelName {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("cloud models")
                .if(appManager.cloudModels.count > 10) { view in
                    view.searchable(text: $cloudModelSearchText, prompt: "search models")
                }
            }
        }
    }

    private func selectCloudModel(_ modelName: String) {
        appManager.currentCloudModelName = modelName
        appManager.currentModelSource = .cloud
        appManager.playHaptic()
    }

    private func fetchCloudModels() {
        let trimmedURL = appManager.cloudAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = OpenAIClient.normalizedBaseURL(from: trimmedURL) else {
            cloudFetchError = "enter a valid api base url"
            return
        }

        isFetchingCloudModels = true
        cloudFetchError = nil

        Task {
            do {
                let models = try await OpenAIClient().listModels(baseURL: baseURL, apiKey: appManager.cloudAPIKey)
                await MainActor.run {
                    appManager.cloudAPIBaseURL = trimmedURL
                    appManager.mergeCloudModels(models)
                    isFetchingCloudModels = false
                }
            } catch {
                await MainActor.run {
                    cloudFetchError = error.localizedDescription
                    isFetchingCloudModels = false
                }
            }
        }
    }
}

#Preview {
    ChatModelsSettingsView()
}
