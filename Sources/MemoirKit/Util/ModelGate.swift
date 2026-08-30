import Foundation

/// One switch that makes every on-device model in this process report itself unavailable.
///
/// ## Why this exists
///
/// The answer suite was described as deterministic and was not, and no amount of fixture data
/// would have fixed it. Two model stages run *in front of* the brain and are reached whatever
/// `--brain` says: ``QueryRewriter/modelRewrite(_:)`` normalises the phrasing, and
/// ``QuestionRouter`` escalates a low-margin routing decision to ``GuidedClassifier``. A third,
/// ``PersonJudge``, runs inside consolidation. All three call Apple's `FoundationModels`, all
/// three return `nil` when it is missing, and the result is backwards: the suite is reproducible
/// on a Mac *without* Apple Intelligence and not on one *with* it. "Runs the same for any
/// contributor" cannot be true while that is.
///
/// So the gate is explicit rather than accidental. `MEMOIR_NO_MODEL=1` means no `FoundationModels`
/// call happens anywhere in this process, and every caller takes the path it already had for a
/// machine that has no model. Those paths are load-bearing and tested, not error handling.
///
/// ## What it is not
///
/// Not a privacy control. `allowCloud` is the promise about egress and ``BrainRouter`` enforces
/// it; this only concerns the *on-device* model, which never leaves the machine either way.
/// Turning it on makes answers worse and more predictable, which is what a gate wants and not
/// what a user wants.
///
/// Read once. A switch that changes mid-run would give two halves of one eval different rules,
/// and the whole point is that the run is one thing.
public enum ModelGate {

    /// True when `MEMOIR_NO_MODEL` is set to anything but an explicit off.
    ///
    /// `0`, `false` and `no` mean off, so setting it to zero reads the way anyone would expect
    /// rather than switching the gate on because the string was non-empty.
    public static let modelsDisabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["MEMOIR_NO_MODEL"]?
            .trimmingCharacters(in: .whitespaces)
            .lowercased(),
            !raw.isEmpty
        else { return false }
        return !["0", "false", "no", "off"].contains(raw)
    }()
}
