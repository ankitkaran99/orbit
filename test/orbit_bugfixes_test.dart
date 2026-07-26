// Regression tests for the bug fixes and optimizations made in this
// session, on top of the existing orbit_test.dart suite. Each group
// documents which fix it's guarding against regressing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_state/orbit.dart';

class _Counter extends OrbitStore {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);

  void incrementThenThrow() => mutate(() {
        _count++;
        throw StateError('boom');
      });

  Future<void> incrementThenThrowAsync() => mutateAsync(() async {
        _count++;
        throw StateError('async boom');
      });

  @override
  Map<String, Object?> debugSnapshot() => {'count': _count};
}

class _ThrowingSnapshotStore extends OrbitStore {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);

  Future<void> incrementAsync() => mutateAsync(() async {
        await Future<void>.delayed(Duration.zero);
        _count++;
      });

  @override
  Map<String, Object?> debugSnapshot() =>
      throw StateError('buggy debugSnapshot');
}

class _ValueEqualStore extends OrbitStore {
  _ValueEqualStore(this.id);
  final int id;
  int resumeCalls = 0;

  @override
  void onResume() => resumeCalls++;

  // Deliberately overrides == for its own domain reasons (e.g.
  // comparing two snapshots by id) — Orbit's internal bookkeeping must
  // not be fooled by this into conflating two different instances.
  @override
  bool operator ==(Object other) => other is _ValueEqualStore && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class _ResumeStore extends OrbitStore {
  int resumeCalls = 0;

  @override
  void onResume() => resumeCalls++;
}

class _ThrowingResumeStore extends OrbitStore {
  @override
  void onResume() => throw StateError('resume boom');
}

// Two distinct ComputedStore subclasses (rather than two
// ComputedStore<int> instances) so each gets its own registry Type —
// Orbit.use() keys singletons by static Type, so two bare
// ComputedStore<int>s would collide with each other regardless of the
// cycle we're trying to test.
late final OrbitStoreRef<_CircularA> circularARef;
late final OrbitStoreRef<_CircularB> circularBRef;

class _CircularA extends ComputedStore<int> {
  _CircularA() : super((watch) => watch(circularBRef).state + 1);
}

class _CircularB extends ComputedStore<int> {
  _CircularB() : super((watch) => watch(circularARef).state + 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    Orbit.resetAll();
    Orbit.clearChangeLog();
    Orbit.debugLogging = true;
  });

  group('fix: failed mutations still reach observe()/changeLog', () {
    test('mutate() records the error and still notifies listeners', () {
      Orbit.debugLogging = true;
      final store = Orbit.use<_Counter>(() => _Counter());
      Orbit.clearChangeLog();

      var notified = 0;
      store.addListener(() => notified++);

      final received = <OrbitMutation>[];
      final unsubscribe = Orbit.observe((s, m) => received.add(m));

      expect(() => store.incrementThenThrow(), throwsStateError);

      expect(notified, 1, reason: 'listeners still get notified on error');
      expect(received, hasLength(1),
          reason: 'observe() must also see the failed mutation');
      expect(received.single.error, isA<StateError>());
      expect(Orbit.changeLog, hasLength(1),
          reason: 'changeLog must also record the failed mutation');
      expect(Orbit.changeLog.single.error, isA<StateError>());
      expect(Orbit.changeLog.single.toString(), contains('threw'));
      expect(store.count, 1); // the increment before the throw stuck

      unsubscribe();
    });

    test('mutateAsync() records the error the same way', () async {
      Orbit.debugLogging = true;
      final store = Orbit.use<_Counter>(() => _Counter());
      Orbit.clearChangeLog();

      await expectLater(store.incrementThenThrowAsync(), throwsStateError);

      expect(Orbit.changeLog, hasLength(1));
      expect(Orbit.changeLog.single.error, isA<StateError>());
    });
  });

  group('fix: debounce/throttle no longer share a timer-id namespace', () {
    test('a debounce and a throttle using the same id do not interfere',
        () async {
      final store = Orbit.use<_Counter>(() => _Counter());
      var debounceCalls = 0;
      var throttleCalls = 0;

      store.debounce('shared_id', const Duration(milliseconds: 10), () {
        debounceCalls++;
      });
      // Same id as the debounce above — must not be swallowed by it.
      store.throttle('shared_id', const Duration(milliseconds: 10), () {
        throttleCalls++;
      });

      expect(throttleCalls, 1,
          reason: 'throttle fires on the leading edge regardless of the '
              'debounce sharing its id');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(debounceCalls, 1,
          reason: 'the debounce still fires after its own delay');
    });
  });

  group('fix: ComputedStore custom equals', () {
    test('bails out on value-equal results instead of always notifying', () {
      final source = defineStore(() => _Counter());
      var notifyCount = 0;

      final computed = ComputedStore<List<int>>(
        // Deliberately returns a *new* List each time, as most real
        // `.where().toList()` derivations do.
        (watch) => List<int>.filled(1, watch(source).count ~/ 2),
        equals: (a, b) => a.length == b.length && a[0] == b[0],
      );
      Orbit.use<ComputedStore<List<int>>>(() => computed);
      computed.addListener(() => notifyCount++);

      source().increment(); // count 1, derived value [0] -> unchanged
      expect(computed.state, [0]);
      expect(notifyCount, 0,
          reason: 'derived value is still [0]; a proper equals must bail');

      source().increment(); // count 2, derived value [1] -> changed
      expect(computed.state, [1]);
      expect(notifyCount, 1);
    });

    test('default == never bails out for List results (documented gap)', () {
      final source = defineStore(() => _Counter());
      var notifyCount = 0;

      // No custom equals: every dependency change notifies even though
      // the derived value is always the same constant list, because a
      // fresh List is never `==` to the previous one.
      final computed = ComputedStore<List<int>>((watch) {
        watch(source); // establish the dependency
        return List<int>.filled(1, 0);
      });
      Orbit.use<ComputedStore<List<int>>>(() => computed);
      computed.addListener(() => notifyCount++);

      source().increment();
      expect(notifyCount, 1,
          reason: 'documents the gap equals is meant to close');
    });
  });

  group('fix: internal bookkeeping is identity-based, not ==-based', () {
    // Note: ComputedStore dependencies are always resolved through
    // Orbit.use<T>(), a Type-keyed singleton cache — so a single
    // ComputedStore can never actually end up watching two *different*
    // instances of the same type via the public API. The reachable
    // scenario for this fix is multiple OrbitScope instances of the
    // same type (e.g. two open dialogs), each with its own store —
    // that's what this test covers.
    testWidgets(
        'two == -equal but distinct scoped instances of the same type are '
        'tracked independently by the shared lifecycle observer',
        (tester) async {
      final a = Orbit.use<_ValueEqualStore>(() => _ValueEqualStore(1));
      expect(a.resumeCalls, 0);

      // A scoped instance that compares == to `a` (same id) but is a
      // genuinely different object, alive at the same time.
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: OrbitScope<_ValueEqualStore>(
          create: () => _ValueEqualStore(1),
          child: const SizedBox(),
        ),
      ));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // Both the global singleton and the scoped instance must have
      // received their own onResume() call — if _liveStores had been a
      // plain (==-based) Set, adding the scoped instance could have
      // been treated as "already present" and silently dropped.
      expect(a.resumeCalls, 1);

      // Unmounting the scope must only remove *that* instance, not
      // accidentally remove `a` because they compare ==.
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(a.resumeCalls, 2,
          reason: 'the global singleton must still be live and tracked '
              'after the ==-equal scoped instance was disposed');
    });
  });

  group('fix: ComputedStore recompute survives a throwing equals', () {
    test(
        'a throwing equals comparator does not freeze state at the stale '
        'value', () {
      final source = defineStore(() => _Counter());
      var callCount = 0;

      final computed = ComputedStore<int>(
        (watch) => watch(source).count,
        equals: (a, b) {
          callCount++;
          if (callCount == 1) {
            throw StateError('buggy equals');
          }
          return a == b;
        },
      );
      Orbit.use<ComputedStore<int>>(() => computed);

      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      try {
        // First recompute hits the throwing branch of equals — must
        // still update _state (fail open) rather than freeze at 0.
        source().increment();
      } finally {
        FlutterError.onError = originalOnError;
      }

      expect(computed.state, 1,
          reason: 'must not get stuck at the stale value just because '
              'equals threw');
      expect(errors, isNotEmpty,
          reason: 'the equals failure should be reported to FlutterError');
    });

    testWidgets('OrbitSelector survives a throwing equals comparator',
        (tester) async {
      final store = defineStore(() => _Counter());
      var callCount = 0;
      var buildCount = 0;

      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: OrbitSelector<_Counter, int>(
              store: store,
              selector: (s) => s.count,
              equals: (prev, next) {
                callCount++;
                if (callCount == 1) {
                  throw StateError('buggy selector equals');
                }
                return prev == next;
              },
              builder: (context, count) {
                buildCount++;
                return Text('Count: $count');
              },
            ),
          ),
        );

        expect(find.text('Count: 0'), findsOneWidget);

        store().increment();
        await tester.pump();

        expect(find.text('Count: 1'), findsOneWidget);
        expect(buildCount, 2);
        expect(errors, isNotEmpty,
            reason: 'OrbitSelector equals failure reported to FlutterError');
      } finally {
        FlutterError.onError = originalOnError;
      }
    });
  });

  group('fix: ComputedStore circular dependency', () {
    test('throws a clear StateError instead of a LateInitializationError', () {
      circularARef = defineStore(() => _CircularA());
      circularBRef = defineStore(() => _CircularB());

      expect(
        () => circularARef(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Circular ComputedStore dependency detected'),
          ),
        ),
      );
    });
  });

  group('fix: dispose() eagerly notifies dependents', () {
    test(
        'a ComputedStore reacts immediately to a dependency reset, without '
        'anything explicitly re-reading .state first', () {
      final source = defineStore(() => _Counter());
      final computed = defineStore(() => ComputedStore<int>((watch) {
            return watch(source).count;
          }));

      source().increment();
      expect(computed().state, 1);

      var notifyCount = 0;
      computed().addListener(() => notifyCount++);

      // Nothing here reads .state between the reset() and the
      // assertion — the dependent must recompute reactively via
      // dispose()'s eager notifyListeners(), not the lazy fallback in
      // the state getter (which only kicks in when .state is read).
      Orbit.reset<_Counter>();

      expect(notifyCount, 1,
          reason: 'dispose() should notify the dependent immediately');
      expect(computed().state, 0,
          reason: 'the dependency was replaced with a fresh instance');
    });
  });

  group('fix: FutureProvider.refresh() error handling', () {
    test('refresh() completes normally on failure; ready/init still throws',
        () async {
      var callCount = 0;
      final provider = FutureProvider<int>(() async {
        callCount++;
        throw StateError('fails every time');
      });

      Orbit.use<FutureProvider<int>>(() => provider);
      await expectLater(provider.ready, throwsStateError,
          reason: 'init() must still surface failures via ready/initError');

      // Calling refresh() directly (as e.g. RefreshIndicator.onRefresh
      // would) must NOT throw, even though the fetch fails again — the
      // error should surface only through `state`.
      await expectLater(provider.refresh(), completes);
      expect(provider.state.hasError, isTrue);
      expect(callCount, 2);
    });
  });

  group('fix: a throwing debugSnapshot() cannot block the real mutation', () {
    test(
        'mutate() still runs the action and notifies, even if '
        'debugSnapshot() throws', () {
      Orbit.debugLogging = true;
      final store =
          Orbit.use<_ThrowingSnapshotStore>(() => _ThrowingSnapshotStore());
      Orbit.clearChangeLog();

      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      var notified = 0;
      store.addListener(() => notified++);

      try {
        // Must NOT throw — a buggy debug-only helper must never block
        // the real mutation from running.
        expect(() => store.increment(), returnsNormally);
      } finally {
        FlutterError.onError = originalOnError;
      }

      expect(store.count, 1,
          reason: 'the action must run despite debugSnapshot() throwing');
      expect(notified, 1);
      expect(errors, isNotEmpty,
          reason: 'the debugSnapshot() bug should still be reported '
              'somewhere, just not by breaking the mutation');
    });

    test('mutateAsync() has the same protection', () async {
      Orbit.debugLogging = true;
      final store =
          Orbit.use<_ThrowingSnapshotStore>(() => _ThrowingSnapshotStore());

      final originalOnError = FlutterError.onError;
      FlutterError.onError = (_) {};
      try {
        await expectLater(store.incrementAsync(), completes);
      } finally {
        FlutterError.onError = originalOnError;
      }

      expect(store.count, 1);
    });
  });

  group('fix: shared app-lifecycle observer', () {
    testWidgets('onResume() fires for every live store on resume',
        (tester) async {
      final a = Orbit.use<_ResumeStore>(() => _ResumeStore());
      // A second store of a different type to make sure the shared
      // observer fans out to more than one store.
      final b = Orbit.use<_Counter>(() => _Counter());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      expect(a.resumeCalls, 1);
      // _Counter doesn't override onResume(), just confirming this
      // doesn't throw for stores that don't care about it either.
      expect(b.count, 0);
    });

    testWidgets('one store throwing in onResume() does not block others',
        (tester) async {
      Orbit.use<_ThrowingResumeStore>(() => _ThrowingResumeStore());
      final ok = Orbit.use<_ResumeStore>(() => _ResumeStore());

      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      try {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);

        expect(ok.resumeCalls, 1,
            reason: 'the throwing store must not block this one');
        expect(errors, hasLength(1));
        expect(errors.single.exception, isA<StateError>());
      } finally {
        FlutterError.onError = originalOnError;
      }
    });
  });

  group(
      'fix: OrbitStoreRef.of() warns when listen:true silently is not '
      'reactive', () {
    testWidgets('warns when there is no ancestor OrbitScope', (tester) async {
      final ref = defineStore(() => _Counter());
      final messages = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      try {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: (context) {
            ref.of(context); // listen: true (default), no scope above
            return const SizedBox();
          }),
        ));
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(
        messages.any((m) => m.contains('WITHOUT actually subscribing')),
        isTrue,
        reason: 'should flag the silent non-reactive fallback',
      );
    });

    testWidgets('does not warn when resolved via an ancestor OrbitScope',
        (tester) async {
      final ref = defineStore(() => _Counter());
      final messages = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: OrbitScope<_Counter>(
              create: () => _Counter(),
              child: Builder(builder: (context) {
                ref.of(context);
                return const SizedBox();
              }),
            ),
          ),
        );
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(messages, isEmpty,
          reason: 'properly scoped access should not warn');
    });

    testWidgets('does not warn for listen: false', (tester) async {
      final ref = defineStore(() => _Counter());
      final messages = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      try {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: (context) {
            ref.of(context, listen: false);
            return const SizedBox();
          }),
        ));
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(messages, isEmpty,
          reason: 'listen: false never claimed to be reactive');
    });
  });

  group('fix: DevTools snapshot safety', () {
    test('_jsonSafe coerces non-JSON-safe values via toString()', () {
      final safe = Orbit.jsonSafeForTest({
        'when': DateTime(2024, 1, 1),
        'nested': [DateTime(2024, 1, 1), 1, 'ok'],
      });

      expect(safe, isA<Map>());
      final map = safe as Map;
      expect(map['when'], isA<String>());
      expect(map['nested'], isA<List>());
      final nested = map['nested'] as List;
      expect(nested[0], isA<String>()); // DateTime -> toString()
      expect(nested[1], 1); // already JSON-safe, passed through
      expect(nested[2], 'ok');
    });

    test('leaves already-JSON-safe values untouched', () {
      expect(Orbit.jsonSafeForTest(null), isNull);
      expect(Orbit.jsonSafeForTest(42), 42);
      expect(Orbit.jsonSafeForTest('x'), 'x');
      expect(Orbit.jsonSafeForTest(true), true);
    });
  });
}
