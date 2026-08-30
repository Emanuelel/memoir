//
//  MemoirFixtures.swift
//  What this module is, and the one rule for changing it.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS MODULE IS A CONTRACT. The integration suites and `memoir-eval-seed` are
//  both written against it. Add to it freely; do not change or remove what is
//  already here.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  ## Why it is a module rather than a file in the test target
//
//  The answer evals need a database that a contributor can regenerate: known captures,
//  known sessions, known arithmetic. The integration suite already had exactly that world
//  and no way to reach it, because it lived inside `Tests/`. The alternative was a second
//  copy for the seeder, and a second copy is the worst outcome available here: both
//  compile, the names are identical, and they drift apart one small edit at a time until
//  the suite and the eval gate disagree about what "the seeded day" means.
//
//  So there is one copy, and it lives here. Nothing in this module needs `@testable`: it is
//  all public `MemoirKit` API, which is what made the move possible at all.
//
//  ## The rules everything in here obeys
//
//  1. Never read the wall clock       → `TestClock.reference` and its offsets.
//  2. Never call `UUID()`             → `TestID.stable(_:)`, derived from the inputs.
//  3. Never touch the real support directory. This module cannot enforce that (it has no
//     scope to bind), so every CALLER must: `TestWorkspace.with` in the suite,
//     `Paths.$supportDirectoryOverride` in the seeder. A seeded world written into
//     `~/Library/Application Support/Memoir` is the user's real memory, corrupted.
//
//  Seeding is deterministic by construction: the same inputs produce byte-identical rows,
//  so a fixture built twice is the same fixture.
//

import Foundation

/// What went wrong while building a seeded world.
///
/// Deliberately its own type rather than a `MemoirError`: nothing here is a product failure,
/// it is a fixture that did not come out the way the fixture says it should.
public enum FixtureError: Error, CustomStringConvertible {

    /// A seeding step produced nothing, which means everything asserted against it is vacuous.
    case seedProducedNothing(String)

    public var description: String {
        switch self {
        case .seedProducedNothing(let what): return "seeding produced no \(what)"
        }
    }
}
