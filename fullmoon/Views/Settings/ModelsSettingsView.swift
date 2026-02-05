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
                selectCloudModel(newValue)
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
