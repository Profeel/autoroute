# AutoRoute Optimization Implementation Plan

> **For Hermes:** Execute task-by-task with a failing test before each behavioral change.

**Goal:** Improve AutoRoute's request lifecycle, routing correctness, persistence latency, and evidence-driven evaluation without expanding unsupported protocol scope.

**Architecture:** Keep routing decisions pure and deterministic, add explicit request lifecycle/cancellation state around proxy and upstream execution, move durable writes behind an ordered asynchronous persistence boundary, and evaluate routing changes against a versioned redacted task corpus with a holdout set. Each task must preserve the existing 80-test baseline and add a focused regression test.

**Tech Stack:** Swift 5.10/6, Swift Package Manager, Foundation URLSession, POSIX loopback HTTP server, XCTest, SwiftUI menu-bar app.

---

## Task 1: Cancel upstream work when a streaming client disconnects ✅

Files:
- Modify: `Sources/AutoModelCore/UpstreamClient.swift`
- Modify: `Sources/AutoModelCore/AutoModelEngine.swift`
- Modify: `Sources/AutoModelCore/ProxyServer.swift`
- Modify: `Sources/AutoModelCore/LoopbackHTTPServer.swift` only if lifecycle signaling needs a socket state helper
- Test: `Tests/AutoModelCoreTests/NativeResponsesTests.swift` or a new focused lifecycle test file

Acceptance:
- A failed local socket write causes the stream callback to throw a typed cancellation error.
- The upstream request is cancelled and no later fallback candidate is attempted.
- The receipt distinguishes client disconnect from ordinary provider/network failure.
- Existing pre-header fallback remains unchanged.

Verification:
- A mock upstream delays or emits multiple SSE chunks.
- The client closes after the first chunk.
- Assert the mock upstream observes cancellation, the second candidate receives no request, and the final receipt records disconnect.

## Task 2: Bound fallback attempts and total request deadline; honor Retry-After ✅

Files:
- Modify: `Sources/AutoModelCore/Models.swift`
- Modify: `Sources/AutoModelCore/AutoModelEngine.swift`
- Modify: `Sources/AutoModelCore/Router.swift` if queue construction needs a policy-bound limit
- Modify: `Sources/AutoModelCore/UpstreamClient.swift` for retry metadata if needed
- Test: `Tests/AutoModelCoreTests/AutoModelTests.swift`

Acceptance:
- Auto-routed requests have an explicit maximum number of attempts and cumulative deadline.
- Explicit model requests do not silently fan out to other models.
- 429 handling records `Retry-After` when available and does not spin through an unbounded queue.
- Attempt receipts explain why remaining candidates were skipped.

## Task 3: Replace unsafe context-length estimation ✅

Files:
- Modify: `Sources/AutoModelCore/Router.swift`
- Modify: `Sources/AutoModelCore/Models.swift` only if estimate provenance belongs in `RequestFeatures`
- Test: new `Tests/AutoModelCoreTests/RequestFeatureEstimationTests.swift`

Acceptance:
- Estimates distinguish measured/provider-reported from conservative local estimates.
- CJK, code, JSON, tools, vision, and boundary-size fixtures are covered.
- Context filtering does not reject a request solely because a low-confidence estimate is slightly over the limit.
- Existing routing rules remain deterministic.

## Task 4: Remove synchronous persistence from the request completion path ✅

Files:
- Modify: `Sources/AutoModelCore/PersistenceStore.swift`
- Modify: `Sources/AutoModelCore/AutoModelEngine.swift`
- Modify: `Sources/AutoModelCore/Models.swift` only if persistence snapshots need a new value type
- Test: new `Tests/AutoModelCoreTests/PersistenceLifecycleTests.swift`

Acceptance:
- MainActor request completion does not synchronously encode/write full history and ledger files.
- Writes preserve order, survive a burst, expose failures, and flush on shutdown.
- Budget accounting remains durable and is not weakened by asynchronous batching.
- Request receipts return without waiting for file I/O; bounded durability is provided by ordered writes and shutdown flush.

## Task 5: Add resource limits and shutdown cancellation to the local HTTP server

Files:
- Modify: `Sources/AutoModelCore/LoopbackHTTPServer.swift`
- Modify: `Sources/AutoModelCore/ProxyServer.swift`
- Test: new `Tests/AutoModelCoreTests/LoopbackResourceLimitTests.swift`

Acceptance:
- Maximum active connections and request body sizes are enforced.
- Excess connections receive a deterministic local error or are closed.
- Stopping the server cancels/ closes active client work.
- Normal concurrent requests remain correct.

## Task 6: Build a redacted routing holdout harness

Files:
- Create: `Sources/AutoModelCore/RoutingEvaluation.swift`
- Create: `Tests/AutoModelCoreTests/RoutingEvaluationTests.swift`
- Modify: `Sources/AutoModelCore/Router.swift` only where the pure decision interface needs stable version metadata
- Modify: `README.md`, `README.zh-CN.md`, `ROADMAP.md`

Acceptance:
- A versioned task corpus can be replayed without provider credentials or request bodies.
- Train and holdout cases are separate and reported separately.
- Metrics include routing accuracy, false rejection, capability fit, estimated cost, and decision latency.
- A strategy change cannot claim improvement when holdout data is missing.

## Task 7: Improve runtime metrics and release gates

Files:
- Modify: `Sources/AutoModelCore/AutoModelEngine.swift`
- Modify: `Sources/AutoModelCore/LocalProductMetrics.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `docs/release/RELEASE_CHECKLIST.md`
- Test: focused metrics and smoke-test coverage

Acceptance:
- Runtime metrics distinguish p50/p95, timeout, 429, provider failure, tool failure, and client disconnect.
- CI runs focused loopback smoke coverage in addition to unit tests and build.
- Real UI, real upstream A/B, and notarization remain explicitly marked as external evidence until executed.

After each task, run the focused tests, then `swift test`, `swift build -c release`, and `git diff --check`. Do not commit or modify unrelated existing work such as `graft/`.
