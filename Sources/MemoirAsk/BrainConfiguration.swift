import Foundation
import MemoirKit

// MARK: - Brain configuration

/// The brain settings for this run, from the chosen brain and the environment.
///
/// One function because there were two copies of this and they disagreed. The question path
/// built a config with an endpoint on it; `--reindex` built one with `allowCloud: false` and
/// nothing else. Neither set `allowLocalNetwork`, so **both were unable to reach a model on the
/// user's own network at all**, including `memoir-ask --brain localNetwork`, which the usage
/// text documents. `BrainRouter.isAllowed` returns `config.allowLocalNetwork` for that kind and
/// it defaults to `false`, so the endpoint was configured and then never used.
///
/// ## Why setting `MEMOIR_LOCAL_URL` is the consent
///
/// `allowLocalNetwork` exists because a model on your own Tailnet is not cloud (no third party,
/// no account, no retention), but the packet still leaves this Mac, so it gets its own switch
/// rather than riding on `allowCloud`. In the app that switch is a checkbox. Here, typing the
/// address of your own box into an environment variable *is* the deliberate act; there is
/// nothing more explicit to ask for, and a flag that silently does nothing is worse than no flag.
///
/// Cloud is derived the same way: from `--brain` naming a cloud brain, and never from the
/// environment.
func brainConfiguration(preferred: BrainKind) -> BrainConfig {
    var config = BrainConfig(allowCloud: preferred == .anthropicAPI || preferred == .claudeCode)

    // Configured from the environment rather than a flag so a batch run can set it once:
    //   MEMOIR_LOCAL_URL=http://host:1234/v1 MEMOIR_LOCAL_MODEL=qwen3-… memoir-ask --brain localNetwork "…"
    if let raw = ProcessInfo.processInfo.environment["MEMOIR_LOCAL_URL"],
       let url = URL(string: raw) {
        config.localNetworkEndpoint = LocalNetworkBrain.Endpoint(
            baseURL: url,
            model: ProcessInfo.processInfo.environment["MEMOIR_LOCAL_MODEL"] ?? "local-model",
            apiKey: ProcessInfo.processInfo.environment["MEMOIR_LOCAL_KEY"]
        )
        config.allowLocalNetwork = true
    }
    return config
}
