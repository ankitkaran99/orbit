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
