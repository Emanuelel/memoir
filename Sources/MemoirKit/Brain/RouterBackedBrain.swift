import Foundation

/// A ``Brain`` that delegates straight to a ``BrainRouter``.
///
/// ``LLMExtractor`` takes a brain, not a router. Handing it a concrete brain would hand it one
/// the caller picked rather than the one the router would actually allow, and the router is
/// where `allowCloud` is enforced. Extraction reads a person's whole screen, so it is the last
/// place that veto should be routed around: wiring `LLMExtractor(brain: AnthropicBrain(...))`
/// directly would post captured text to a third party while `allowCloud` was false, which is
/// CF-2 broken at the one stage that sees the most.
///
/// So the extractor is given the router wearing a brain's clothes. The fallback chain, the
/// availability cache and the cloud veto all still apply, and there is exactly one place that
/// decides which model runs.
///
/// Only ``isAvailable()`` and ``complete(prompt:maxTokens:)`` are used by the extraction path;
/// ``answer(question:context:)`` is here for the protocol and forwards like the rest.
public struct RouterBackedBrain: Brain {

    private let router: BrainRouter

    /// Creates a brain that forwards every call to `router`.
    public init(router: BrainRouter) {
        self.router = router
    }

    /// Reported for the protocol's sake only; the router decides which brain really runs.
    ///
    /// `.rulesOnly` rather than the router's current pick because this value is read
    /// synchronously and the router's answer is `async`, and a stale kind displayed as fact
    /// would be worse than an obviously conservative one. Nothing on the extraction path
    /// reads it.
    public var kind: BrainKind { .rulesOnly }

    /// True only when a brain that can genuinely complete free text is in the chain.
    ///
    /// **Not `true` unconditionally, which is the obvious version and is wrong.** The router's
    /// last link is ``RulesOnlyBrain``, which is always available, so answering `true` here
    /// would defeat ``LLMExtractor``'s own availability guard and send it down a path that
    /// cannot work: `RulesOnlyBrain.complete` treats its prompt as a *question* and renders a
    /// templated answer, so the extractor would post a JSON-shaped instruction, receive prose,
    /// fail to parse it, and discard the batch. Harmless, silent, and indistinguishable from an
    /// extractor that is working and finding nothing, which is the failure this whole change
    /// exists to stop repeating.
    ///
    /// So the question asked here is the one the extractor actually means: is there a model, or
    /// only the floor?
    public func isAvailable() async -> Bool {
        await router.available().contains { $0 != .rulesOnly }
    }

    /// True only when the router can reach a model bigger than the on-device one.
    ///
    /// The default would say yes whenever anything but `rulesOnly` is in the chain, and on a
    /// Mac whose only model is Apple's that means asking a 3B for free-text JSON: the exact
    /// thing that failed on two runs in six and gave `GuidedExtractor` its reason to exist.
    ///
    /// So: a model the user actually configured (theirs over the network, or a cloud one they
    /// turned on) extracts, because it is better at reading raw screen text than the on-device
    /// model is. With nothing but the on-device model in the chain, guided extraction takes it
    /// instead. Answering is unaffected; this decides extraction only.
    public func preferredForExtraction() async -> Bool {
        await router.available().contains { $0 != .rulesOnly && $0 != .appleOnDevice }
    }

    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        try await router.answer(question: question, context: context)
    }

    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        try await router.complete(prompt: prompt, maxTokens: maxTokens)
    }
}
