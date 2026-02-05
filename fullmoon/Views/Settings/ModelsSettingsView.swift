//
//  ModelsSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI
import MLXLMCommon

struct ModelsSettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(LLMEvaluator.self) var llm
    @State var showOnboardingInstallModelView = false
    @State private var isFetchingCloudModels = false
    @State private var cloudFetchError: String?
    @State private var newCloudModelName = ""
    
    var body: some View {
        Form {
            Section(header: Text("installed")) {
                ForEach(appManager.installedModels, id: \.self) { modelName in
                    Button {
                        Task {
                            await switchModel(modelName)
                        }
                    } label: {
                        Label {
                            Text(appManager.modelDisplayName(modelName))
                                .tint(.primary)
                        } icon: {
                            Image(systemName: appManager.currentModelSource == .local && appManager.currentModelName == modelName ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                }
            }
            
            Button {
                showOnboardingInstallModelView.toggle()
            } label: {
                Label("install a model", systemImage: "arrow.down.circle.dotted")
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif

            Section(header: Text("cloud endpoint")) {
                TextField("API base URL (OpenAI-compatible)", text: $appManager.cloudAPIBaseURL)
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                SecureField("API key (optional)", text: $appManager.cloudAPIKey)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                HStack(spacing: 12) {
                    Button {
                        fetchCloudModels()
                    } label: {
                        Label("fetch models", systemImage: "arrow.clockwise")
                    }
                    .disabled(isFetchingCloudModels || appManager.cloudAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isFetchingCloudModels {
                        ProgressView()
                    }
                }

                if let cloudFetchError {
                    Text(cloudFetchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("cloud models")) {
                if appManager.cloudModels.isEmpty {
                    Text("no cloud models yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appManager.cloudModels, id: \.self) { modelName in
                        Button {
                            selectCloudModel(modelName)
                        } label: {
                            Label {
                                Text(modelName)
                                    .tint(.primary)
                            } icon: {
                                Image(systemName: appManager.currentModelSource == .cloud && appManager.currentCloudModelName == modelName ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        #if os(macOS)
                        .buttonStyle(.borderless)
                        #endif
                    }
                }
            }

            Section(header: Text("add custom model")) {
                HStack(spacing: 12) {
                    TextField("model id", text: $newCloudModelName)
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    Button("add") {
                        addCustomCloudModel()
                    }
                    .disabled(newCloudModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showOnboardingInstallModelView) {
            NavigationStack {
                OnboardingInstallModelView(showOnboarding: $showOnboardingInstallModelView)
                    .environment(llm)
                    .toolbar {
                        #if os(iOS) || os(visionOS)
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: { showOnboardingInstallModelView = false }) {
                                Image(systemName: "xmark")
                            }
                        }
                        #elseif os(macOS)
                        ToolbarItem(placement: .destructiveAction) {
                            Button(action: { showOnboardingInstallModelView = false }) {
                                Text("close")
                            }
                        }
                        #endif
                    }
            }
        }
    }
    
    private func switchModel(_ modelName: String) async {
        if let model = ModelConfiguration.availableModels.first(where: {
            $0.name == modelName
        }) {
            appManager.currentModelName = modelName
            appManager.currentModelSource = .local
            appManager.playHaptic()
            await llm.switchModel(model)
        }
    }

    private func selectCloudModel(_ modelName: String) {
        appManager.currentCloudModelName = modelName
        appManager.currentModelSource = .cloud
        appManager.playHaptic()
    }

    private func addCustomCloudModel() {
        let trimmed = newCloudModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appManager.addCloudModel(trimmed)
        appManager.currentCloudModelName = trimmed
        appManager.currentModelSource = .cloud
        newCloudModelName = ""
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
    ModelsSettingsView()
}
