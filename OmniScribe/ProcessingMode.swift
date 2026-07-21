import Foundation

/// The work modes the user picks from before dictating. Each mode is just a
/// system prompt: the transcribed speech is sent as the user turn, and the
/// prompt reshapes it (fix grammar, draft an email, format code, etc.).
///
/// Prompts deliberately end with an "output only the result" instruction so the
/// model never adds a preamble that would then get pasted into the user's app.
enum ProcessingMode: String, CaseIterable, Codable {
    case ltTyping     = "LT_Typing"
    case email        = "Email"
    case code         = "Code"
    case messenger    = "Messenger"
    case translation  = "Translation"

    var displayName: String {
        switch self {
        case .ltTyping:    return "Typing / Cleanup"
        case .email:       return "Email"
        case .code:        return "Code"
        case .messenger:   return "Messenger"
        case .translation: return "Translation"
        }
    }

    /// The system prompt applied to the raw transcription for this mode.
    var systemPrompt: String {
        switch self {
        case .ltTyping:
            return """
            You clean up dictated speech. Fix grammar, punctuation, and \
            capitalization in the text below while keeping its original language \
            and meaning exactly. Remove filler words (um, uh) and false starts. \
            Do not translate, summarize, or add anything. Output only the cleaned text.
            """
        case .email:
            return """
            Rewrite the dictated text below into a clear, professional business \
            email in the same language as the input. Keep the sender's intent and \
            facts; improve tone and structure. Do not invent recipients, subjects, \
            or signatures unless present. Output only the email body.
            """
        case .code:
            return """
            The text below is a spoken description of code or a spoken code \
            snippet. Convert it into correct, idiomatic source code. Infer the \
            language from context; if ambiguous, use the language named in the \
            text. Output only the code, with no explanation and no Markdown fences.
            """
        case .messenger:
            return """
            Rewrite the dictated text below as a short, casual instant message in \
            the same language as the input. Keep it natural and concise. Do not \
            add greetings or sign-offs unless dictated. Output only the message.
            """
        case .translation:
            return """
            Translate the dictated text below into English, preserving meaning and \
            tone. If the text is already in English, translate it into Lithuanian \
            instead. Output only the translation.
            """
        }
    }
}
