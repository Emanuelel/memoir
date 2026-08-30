import Foundation

/// The pane a navigation sentence points at. Mirrors the shell's tabs without
/// depending on the UI layer.
public enum PaneIntent: String, Sendable, Equatable {
    case chat, todos, notes, today
}

/// Deterministic commands the chat understands *before* any routing or model call.
///
/// These are verbs, not questions: switching a pane is a thing the shell does, and putting it
/// through an answer pipeline would be a category error. Matching is deliberately literal: a
/// phrase either is one of these commands or it goes to the router untouched.
///
/// There were two more: start and end a focus timer. The timer is gone, and with it the only
/// verbs here that did something to the world rather than move the eye.
public enum ChatCommand: Sendable, Equatable {
    /// "what's on my list" / "show my todos". Navigation is a sentence.
    case navigate(PaneIntent)

    /// Detects a command, or returns nil so the sentence flows to the router.
    public static func detect(_ text: String) -> ChatCommand? {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        // Navigation sentences. Only list-shaped asks: "what's overdue" wants the
        // Todos pane, but "did I promise marco anything" is a real recall question
        // and must stay one.
        let todoForms = ["what's on my list", "whats on my list", "show my todos", "show todos",
                         "open todos", "my todo list", "what's overdue", "whats overdue",
                         "show my list", "what is on my list"]
        if todoForms.contains(where: q.contains) { return .navigate(.todos) }
        let todayForms = ["show my day", "show today", "open today", "how's my day looking",
                          "hows my day looking"]
        if todayForms.contains(where: q.contains) { return .navigate(.today) }
        let noteForms = ["show my notes", "open notes", "show notes"]
        if noteForms.contains(where: q.contains) { return .navigate(.notes) }

        return nil
    }
}
