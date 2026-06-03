import Foundation
import Security
import SwiftUI

enum Keychain {
    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct APIKeySetupView: View {
    @Binding var isPresented: Bool
    @State private var ttsProvider: TTSProviderType  = AppSettings.ttsProvider
    @State private var llmProvider: LLMProviderType  = AppSettings.llmProvider
    @State private var deepgramKey:  String = Keychain.get("deepgramAPIKey")  ?? ""
    @State private var openaiKey:    String = Keychain.get("openaiAPIKey")    ?? ""
    @State private var anthropicKey: String = Keychain.get("anthropicAPIKey") ?? ""

    var body: some View {
        NavigationView {
            Form {
                // MARK: TTS
                Section(header: Text("TTS Provider")) {
                    Picker("Provider", selection: $ttsProvider) {
                        ForEach(TTSProviderType.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                switch ttsProvider {
                case .deepgram:
                    Section(header: Text("Deepgram API Key")) {
                        SecureField("Enter key", text: $deepgramKey)
                    }
                    Section { Text("deepgram.com — voice: aura-asteria-en").font(.caption).foregroundColor(.secondary) }
                case .openai:
                    Section(header: Text("OpenAI API Key")) {
                        SecureField("sk-…", text: $openaiKey)
                    }
                    Section { Text("platform.openai.com — tts-1, nova voice").font(.caption).foregroundColor(.secondary) }
                }

                // MARK: LLM polish
                Section(header: Text("Text Polish LLM")) {
                    Picker("Model", selection: $llmProvider) {
                        ForEach(LLMProviderType.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    if llmProvider != .none {
                        HStack {
                            Text(llmProvider.costLabel).font(.caption).foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                if llmProvider.needsAnthropicKey {
                    Section(header: Text("Anthropic API Key")) {
                        SecureField("sk-ant-…", text: $anthropicKey)
                    }
                    Section { Text("console.anthropic.com — used for text polish and figure narration").font(.caption).foregroundColor(.secondary) }
                }
                if llmProvider.needsOpenAIKey && ttsProvider != .openai {
                    Section(header: Text("OpenAI API Key")) {
                        SecureField("sk-…", text: $openaiKey)
                    }
                    Section { Text("platform.openai.com — used for text polish and figure narration").font(.caption).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(
                leading: Button("Cancel") { isPresented = false },
                trailing: Button("Save") { save() }.disabled(!canSave)
            )
        }
    }

    private var canSave: Bool {
        switch ttsProvider {
        case .deepgram: guard !deepgramKey.isEmpty else { return false }
        case .openai:   guard !openaiKey.isEmpty   else { return false }
        }
        if llmProvider.needsAnthropicKey && anthropicKey.isEmpty { return false }
        if llmProvider.needsOpenAIKey    && openaiKey.isEmpty    { return false }
        return true
    }

    private func save() {
        if !deepgramKey.isEmpty  { Keychain.set(deepgramKey,  forKey: "deepgramAPIKey") }
        if !openaiKey.isEmpty    { Keychain.set(openaiKey,    forKey: "openaiAPIKey") }
        if !anthropicKey.isEmpty { Keychain.set(anthropicKey, forKey: "anthropicAPIKey") }
        AppSettings.ttsProvider = ttsProvider
        AppSettings.llmProvider = llmProvider
        isPresented = false
    }
}
