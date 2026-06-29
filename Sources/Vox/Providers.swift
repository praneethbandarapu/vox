import Foundation

// Pluggable provider interfaces. The rest of the app talks only to these
// protocols, never to a concrete service. Swapping a component (Claude -> a
// local LLM, Deepgram -> on-device Whisper) means: add a type that conforms
// here, then add one case to the factory. Selection is driven by settings,
// ready for a future "choose your provider" menu.

// Speech-to-text. Stream-oriented: start, feed audio chunks, finish for text.
protocol Transcriber: AnyObject {
    var isConfigured: Bool { get }   // e.g. required API key present
    func start()
    func send(_ pcm16: Data)
    func finish() async -> String
}

// Post-processing of a transcript (cleanup, formatting, later: commands).
protocol TextCleaner {
    var displayName: String { get }   // for the menu
    var keyAccount: String { get }    // Keychain account holding its API key
    func clean(_ text: String) async -> String?
}

extension TextCleaner {
    var isConfigured: Bool { Keychain.exists(account: keyAccount) }
}

// Shared instruction used by every cleanup provider, so they behave the same.
let dictationCleanupPrompt = """
You clean up voice dictation transcripts. Fix capitalization, punctuation, \
and obvious transcription errors. Remove filler words like "um", "uh", "like", \
and false starts. Do NOT add, remove, or answer anything: return only the \
cleaned version of the text, nothing else.
"""

enum Settings {
    static var sttProvider: String {
        get { UserDefaults.standard.string(forKey: "sttProvider") ?? "deepgram" }
        set { UserDefaults.standard.set(newValue, forKey: "sttProvider") }
    }
    static var llmProvider: String {
        get { UserDefaults.standard.string(forKey: "llmProvider") ?? "groq" }
        set { UserDefaults.standard.set(newValue, forKey: "llmProvider") }
    }
}

enum ProviderFactory {
    static func makeTranscriber() -> Transcriber {
        switch Settings.sttProvider {
        case "deepgram": return DeepgramStream()
        // case "whisperkit": return WhisperKitTranscriber()   // M4, on-device
        default: return DeepgramStream()
        }
    }

    static func makeCleaner() -> TextCleaner {
        switch Settings.llmProvider {
        case "groq":      return GroqCleaner()
        case "anthropic": return AnthropicCleaner()
        // case "openai":   return OpenAICleaner()
        // case "local":    return LocalLLMCleaner()            // on-device, no key
        default: return GroqCleaner()
        }
    }
}
