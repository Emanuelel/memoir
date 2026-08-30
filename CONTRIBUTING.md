# Contributing

Issues and pull requests are welcome. A few things about this repository will save you an
afternoon.

## The specification is a file, and it comes first

[`FLOWS.md`](FLOWS.md) is the specification. Every core behaviour is a numbered flow (CF-1,
CF-14b, and so on) with a stated pass condition, and each has a test. **If you change what the
product does, change the flow first.** A pull request that alters behaviour without touching its
flow is incomplete, and the numbers are how the tests, the docs and the evals stay in agreement.

[`ARCHITECTURE.md`](ARCHITECTURE.md) is the interface contract. Public signatures are written
down there before they are written in Swift.

## Before you push

```bash
swift build && swift test
```

The suite is fast. CF-1 (a user's correction is permanent) is the one that must never go red.

For anything touching answers, run the eval gate too:

```bash
bash Scripts/verify.sh --fast
```

It seeds its own database and grades answers against it, so a green run means nothing regressed.
It does not mean every answer is good; [`EVALS.md`](EVALS.md) explains the difference.

## The constraints that are not up for negotiation

These are design decisions, not preferences, and a pull request that breaks one will be asked to
change rather than debated:

- **No third-party dependencies.** Apple frameworks and the system SQLite. This is what makes the
  build reliable, and it is the reason there is no vector index.
- **No screenshots, no screen recording, no ambient audio, no keylogging.**
- **Nothing inferred overwrites anything authored.**
- **The MCP database stays read-only.** An agent may propose; only the user's accept writes.
- **Swift 6 strict concurrency.** Everything crossing an actor boundary is `Sendable`.

## Style

Match the file you are editing. Comments here are unusually long by most standards: they exist to
record a constraint or a measurement that the code cannot show on its own: why a limit is the
number it is, what was measured and when, what broke last time. Comments that restate the next
line are not wanted. If you quote a number, say when you measured it.

Do not put real personal data in the repository. Fixtures use an invented world (Motionvane,
Lumenfield, Fenwick), and new ones should join it.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
