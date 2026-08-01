## 0.5.3

- **Fix (`OrbitStore.mutate` / `mutateAsync`)**: `developer.postEvent` (which drives the VS Code state inspector) was silently gated behind the `debugLogging || _hasObservers` tracking flag. It now always fires in non-release builds regardless of whether debug logging or observers are active, so the extension panel stays live even when `Orbit.debugLogging = false`.
- **Fix (VS Code Extension)**: Flutter hot-reload resets Dart VM stream subscriptions, causing the extension to go permanently blind after the first reload. The extension now subscribes to the `Isolate` VM stream, resubscribes to the `Extension` stream and re-fetches stores on every `IsolateReload` event.
- **Fix (VS Code Extension)**: Resolved a startup race condition where the extension connected before `Orbit.use()` was called. The extension now listens for `ServiceExtensionAdded` on the `Isolate` stream and fetches stores the moment `ext.orbit.getStores` becomes available.

## 0.5.2

- **Fix (VS Code Extension)**: Added depth limit (8 levels) to the state tree renderer to prevent a call-stack overflow when inspecting deeply-nested store state objects.

## 0.5.1

- **Fix (`ComputedStore`)**: Wrapped `_runCompute()` in `_recompute()` with a `try/catch` to prevent a buggy compute function from crashing the upstream dependency store's `mutate()` call.
- **Fix (`OrbitStore.watch`)**: Added error handling for async `onChange` callbacks to catch unhandled Future rejections and route them to `FlutterError.reportError`.
- **Optimization**: Gated `developer.postEvent` behind `!kReleaseMode` to eliminate map allocation overhead in production builds.
- **Fix (VS Code Extension)**: Upgraded `Buffer.slice()` to `Buffer.subarray()` to avoid deprecation warnings and memory leaks.
- **Fix (VS Code Extension)**: Corrected connection backoff state so that a reconnect resets the exponential timer back to 1s.
- **Fix (VS Code Extension)**: Resolved `ext.orbit.getStores` polling by replacing the unbounded 150ms retry loop with capped exponential backoff.
- **Fix (VS Code Extension)**: Handled `streamListen` `subExt` VM service responses, explicitly ignoring harmless "already subscribed" errors and warning on actual failures.
- **Fix (VS Code Extension)**: Prevented a double-event bug where TCP connection drops caused a jarring "Error" then "Disconnected" UI flash, and nulled the stale `_ws` reference appropriately.
- **Fix (VS Code Extension)**: Wrapped `createStore` file writing in a `try/catch` block to handle permissions or disk errors gracefully instead of failing silently.
- **Docs**: Corrected anti-patterns in the `README.md` examples.

## 0.5.0

- Added Scoped Store inspection support in Dart VM Service protocol (`ext.orbit.getStores`) and VS Code State Inspector.
- Added live real-time state mutation events for scoped store instances (`storeKey`).
- Optimized scoped store registry memory tracking using identity sets.

## 0.4.0

- Added official VS Code Extension for state inspection, code snippets, and store generation.
- Improved complex object, map, and list structure debugging in Orbit DevTools extension.

## 0.3.9

- Updated isolate state documentation in `README.md`.

## 0.3.8

- Protected `OrbitSelector.equals` custom comparators against throwing exceptions, matching the error isolation added to `ComputedStore`. A throwing comparator now fails open (treats state as changed and reports to `FlutterError`) to prevent frozen UI updates.
- Added regression tests for `OrbitSelector` throwing equality comparators.
- Updated documentation in `README.md` clarifying isolate boundary behaviors and identity tracking.

## 0.3.7

- fix(orbit): identity-based internal tracking, throwing equals(), and a self-inflicted doc regression

    - Orbit._liveStores, ComputedStore._dependencies, and the local
    activeDeps set now use Set.identity()/Map.identity() instead of
    plain collections. These track object identity of store instances,
    not a possibly user-overridden ==/hashCode — nothing stops an
    OrbitStore subclass from overriding equality for its own domain
    reasons, and doing so must not let Orbit's internal bookkeeping
    conflate two distinct instances. _computeStack's circular-dependency
    check now uses identical() instead of List.contains()'s ==, for the
    same reason (no .identity() constructor exists for List). Verified
    the reachable case is multiple OrbitScope instances of the same type
    (e.g. two open dialogs) — a single ComputedStore can't actually end
    up depending on two different instances of one type today, since
    Orbit.use<T>() is a Type-keyed singleton cache, but the fix is free
    and future-proofs it regardless.

    - ComputedStore._recompute(): protect the equals comparator the same
    way debugSnapshot() was protected last pass. A throwing custom
    equals previously left _state permanently frozen at the stale value
    (the exception fired after _runCompute() already produced the
    correct new value, but before mutate() applied it) — every
    subsequent dependency change would keep hitting the same broken
    comparator and keep failing to update. Now fails open (treats it as
    changed, applies the update) and reports the error separately,
    since a possibly-redundant notify is far less harmful than a
    ComputedStore stuck forever.

    - Fix a self-inflicted doc-comment regression in OrbitStore: when
    _safeSnapshot() was added directly above mutate() a few commits ago,
    mutate()'s full doc comment (label inference, debugSnapshot diffing
    behavior) ended up attached to _safeSnapshot() instead, since a ///
    comment always binds to the next declaration. Because
    _safeSnapshot() is private, dartdoc never rendered any of it —
    mutate(), the single most important @protected method in the
    library, had effectively lost its documentation. Split the comment
    back apart: _safeSnapshot() gets its own short note, mutate() gets
    its original doc back.

    - test/orbit_bugfixes_test.dart: add regression coverage for the
    identity-based tracking (two ==-equal-but-distinct OrbitScope
    instances of the same type both get independent onResume() dispatch
    and independent lifecycle teardown) and the throwing-equals fix
    (state advances past a comparator that throws once, instead of
    freezing).

    - Traced by hand against the existing suite; no regressions expected.

## 0.3.6

- Protected `mutate()` and `mutateAsync()` from throwing `debugSnapshot()` calls.
- Protected `ext.orbit.getStores` DevTools extension against `debugSnapshot()` exceptions per-store.
- Added debug-only warning on non-reactive `OrbitStoreRef.of(context)` fallback when `listen: true` (default) is used without an `OrbitScope`.

## 0.3.5

- Reverted library entry point to `package:orbit_state/orbit.dart`.
- Fixed circular-dependency guard gap on `ComputedStore.state` read.
- Exposed `Orbit.jsonSafeForTest` for DevTools snapshot unit testing.
- Added comprehensive regression tests in `test/orbit_bugfixes_test.dart`.

## 0.3.4

- Updated code formatting and state management refinements.

## 0.3.3

- Fixed dependency cleanup in `ComputedStore` to prevent listener leaks.
- Improved stack frame parsing in `OrbitStore` for robust store label inference.

## 0.3.2

- Added Dart VM Service protocol integration (`ext.orbit.getStores` service extension and `orbit:state-changed` event dispatching) to support DevTools and VS Code State Inspector integrations.

## 0.3.1

- Fixed LICENSE file formatting to comply with standard SPDX MIT license template for correct pub.dev detection.
- Fixed installation snippet and library imports in README.md.
- Added state-management and flutter topics in pubspec.yaml.
- Added GitHub Actions workflow CI verification.
- Improved and extended correctness test suite (added tests for throttle disposal, conditional ComputedStore dependency tracking, and web stack trace label inference).

## 0.3.0


- Added Async & Caching support (`FutureProvider`, `StreamProvider`, and `AsyncValue`).
- Added declarative combining state (`ComputedStore`) and imperative store watching (`watch()`) with automatic subscription tracking and recovery.
- Added built-in side-effect helpers (`debounce()` and `throttle()`) directly on `OrbitStore` with safety error-isolation.
- Added compile-time safe lookups (`OrbitStoreRef.of` and context overloads) with fallback to global singletons to prevent runtime crashes.

## 0.2.2

- Updated package homepage, repository, and issue tracker URLs to valid repo (`https://github.com/ankitkaran99/orbit`).
- Added `lib/orbit_state.dart` matching package name convention.
- Standardized `LICENSE` file for pub.dev recognition.

## 0.2.1

- Automatically infer mutation action labels from caller method names when `label` parameter is omitted.

## 0.2.0

- Initial stable release.
