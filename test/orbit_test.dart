import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_state/orbit.dart';

class CounterStore extends OrbitStore {
  int _count = 0;
  int initCalls = 0;
  int disposeCalls = 0;

  int get count => _count;
  int get doubleCount => _count * 2;

  void increment() => mutate(() => _count++);

  R runMutate<R>(R Function() action) => mutate(action);

  Future<R> runMutateAsync<R>(Future<R> Function() action) =>
      mutateAsync(action);

  Future<void> incrementAsync() async {
    await mutateAsync(() async {
      await Future<void>.delayed(Duration.zero);
      _count++;
    });
  }

  @override
  Map<String, Object?> debugSnapshot() => {'count': _count};

  @override
  FutureOr<void> init() {
    initCalls++;
  }

  @override
  void onDispose() => disposeCalls++;
}

class CounterStoreA extends CounterStore {}

class CounterStoreB extends CounterStore {}

class FlagStore extends CounterStore {}

class FailingInitStore extends OrbitStore {
  int attempts = 0;

  @override
  FutureOr<void> init() {
    attempts++;
    throw StateError('boom');
  }
}

class AsyncInitStore extends OrbitStore {
  bool loaded = false;

  @override
  Future<void> init() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    loaded = true;
  }
}

class AsyncFailingInitStore extends OrbitStore {
  @override
  Future<void> init() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    throw StateError('async boom');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    Orbit.resetAll();
    Orbit.clearChangeLog();
    Orbit.debugLogging = true;
  });

  group('singleton registry', () {
    test('use() returns the same singleton on repeated calls', () {
      final a = Orbit.use<CounterStore>(() => CounterStore());
      final b = Orbit.use<CounterStore>(() => CounterStore());
      expect(identical(a, b), isTrue);
    });

    test('mutate() updates state and notifies listeners', () {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var notified = 0;
      store.addListener(() => notified++);

      store.increment();

      expect(store.count, 1);
      expect(store.doubleCount, 2);
      expect(notified, 1);
    });

    test('mutateAsync() notifies once the awaited action completes', () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var notified = 0;
      store.addListener(() => notified++);

      await store.incrementAsync();

      expect(store.count, 1);
      expect(notified, 1);
    });

    test(
        'reset() disposes the store, runs onDispose(), and clears the '
        'singleton', () {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.reset<CounterStore>();
      final fresh = Orbit.use<CounterStore>(() => CounterStore());

      expect(identical(store, fresh), isFalse);
      expect(store.disposeCalls, 1);
      expect(Orbit.read<CounterStore>(), same(fresh));
    });

    test('read() returns null before the store is created', () {
      expect(Orbit.read<CounterStore>(), isNull);
    });

    test('override() swaps in a fake store, disposing the previous one', () {
      final real = Orbit.use<CounterStore>(() => CounterStore());

      Orbit.override<CounterStore>(CounterStore());

      final current = Orbit.read<CounterStore>();
      expect(identical(current, real), isFalse);
      expect(real.disposeCalls, 1);
      // The old instance is disposed; mutate() checks _disposed
      // internally before calling notifyListeners(), so this is a
      // no-op, not a crash.
      expect(() => real.increment(), returnsNormally);
    });

    test('defineStore() centralizes the factory across call sites', () {
      var constructedWith = -1;
      final ref = defineStore(() {
        constructedWith = 7;
        return CounterStore();
      });

      final a = ref();
      // A "different" factory passed directly is never invoked once the
      // store exists — defineStore makes that the only factory in the
      // first place, so there's no way to accidentally diverge.
      var otherFactoryRan = false;
      final b = Orbit.use<CounterStore>(() {
        otherFactoryRan = true;
        return CounterStore();
      });

      expect(identical(a, b), isTrue);
      expect(constructedWith, 7);
      expect(otherFactoryRan, isFalse);
    });
  });

  group('init()', () {
    test('a synchronous init() runs immediately; ready completes', () {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      expect(store.initCalls, 1);
      expect(store.isReady, isTrue);
      expect(store.initError, isNull);
    });

    test('init() runs exactly once even across repeated use() calls', () {
      final a = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.use<CounterStore>(() => CounterStore());
      expect(a.initCalls, 1);
    });

    test(
        'an async init() leaves the store usable immediately, '
        'ready completes once it finishes', () async {
      final store = Orbit.use<AsyncInitStore>(() => AsyncInitStore());
      expect(store.loaded, isFalse);
      expect(store.isReady, isFalse);

      await store.ready;

      expect(store.loaded, isTrue);
      expect(store.isReady, isTrue);
    });

    test('a synchronously-throwing init() prevents registration', () {
      expect(
        () => Orbit.use<FailingInitStore>(() => FailingInitStore()),
        throwsStateError,
      );
      expect(Orbit.read<FailingInitStore>(), isNull);

      final secondAttempt = FailingInitStore();
      expect(
        () => Orbit.use<FailingInitStore>(() => secondAttempt),
        throwsStateError,
      );
      expect(secondAttempt.attempts, 1);
      expect(Orbit.read<FailingInitStore>(), isNull);
    });

    test(
        'an asynchronously-throwing init() still registers the store, '
        'but records the error on ready/initError', () async {
      final store =
          Orbit.use<AsyncFailingInitStore>(() => AsyncFailingInitStore());

      expect(Orbit.read<AsyncFailingInitStore>(), same(store));

      await expectLater(store.ready, throwsStateError);

      expect(store.initError, isA<StateError>());
      expect(store.isReady, isFalse);
    });
  });

  group('debug logging & observe()', () {
    test(
        'mutate() records a change with a diff when debugSnapshot '
        'is overridden', () {
      Orbit.debugLogging = true;
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.clearChangeLog();

      store.increment();

      expect(Orbit.changeLog, hasLength(1));
      final change = Orbit.changeLog.single;
      expect(change.store, same(store));
      expect(change.action, 'increment');
      expect(change.diff, {'count': (0, 1)});
    });

    test('changeLog is capped at the most recent 200 entries', () {
      Orbit.debugLogging = true;
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.clearChangeLog();

      for (var i = 0; i < 250; i++) {
        store.increment();
      }

      expect(Orbit.changeLog, hasLength(200));
      expect(Orbit.changeLog.last.diff['count'], (249, 250));
    });

    test('nothing is logged when debugLogging is off and no observers', () {
      Orbit.debugLogging = false;
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.clearChangeLog();

      store.increment();

      expect(Orbit.changeLog, isEmpty);
    });

    test('observe() fires for every mutation, even with debugLogging off', () {
      Orbit.debugLogging = false;
      final store = Orbit.use<CounterStore>(() => CounterStore());

      final received = <OrbitMutation>[];
      final unsubscribe = Orbit.observe((s, m) => received.add(m));

      store.increment();
      store.increment();

      unsubscribe();
      store.increment();

      expect(received, hasLength(2));
      expect(received.every((m) => m.store == store), isTrue);
      // Not persisted to changeLog since debugLogging is off — observe()
      // and the console/changeLog are independent.
      expect(Orbit.changeLog, isEmpty);
    });

    test('OrbitMutation.listenerCount reflects active listeners', () {
      Orbit.debugLogging = true;
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.clearChangeLog();

      void l1() {}
      void l2() {}
      store.addListener(l1);
      store.addListener(l2);

      store.increment();

      expect(Orbit.changeLog.single.listenerCount, 2);

      store.removeListener(l1);
      store.increment();

      expect(Orbit.changeLog.last.listenerCount, 1);
    });
  });

  group('OrbitScope', () {
    testWidgets('provides an independent instance per scope', (tester) async {
      late CounterStore scopedA;
      late CounterStore scopedB;

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              OrbitScope<CounterStore>(
                create: () => CounterStore(),
                child: Builder(builder: (context) {
                  scopedA = OrbitScope.of<CounterStore>(context);
                  return const SizedBox();
                }),
              ),
              OrbitScope<CounterStore>(
                create: () => CounterStore(),
                child: Builder(builder: (context) {
                  scopedB = OrbitScope.of<CounterStore>(context);
                  return const SizedBox();
                }),
              ),
            ],
          ),
        ),
      );

      scopedA.increment();

      expect(scopedA.count, 1);
      expect(scopedB.count, 0);
      expect(identical(scopedA, scopedB), isFalse);
      // Scoped stores never touch the global registry.
      expect(Orbit.read<CounterStore>(), isNull);
    });

    testWidgets('OrbitBuilder inside a scope uses the scoped instance',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OrbitScope<CounterStore>(
            create: () => CounterStore(),
            child: OrbitBuilder<CounterStore>(
              store: () => CounterStore(), // must be ignored in favor of scope
              builder: (context, store, child) => Text('${store.count}'),
            ),
          ),
        ),
      );

      expect(find.text('0'), findsOneWidget);
      expect(Orbit.read<CounterStore>(), isNull);
    });

    testWidgets('disposes its store when removed from the tree',
        (tester) async {
      late CounterStore store;

      await tester.pumpWidget(
        MaterialApp(
          home: OrbitScope<CounterStore>(
            create: () => CounterStore(),
            child: Builder(builder: (context) {
              store = OrbitScope.of<CounterStore>(context);
              return const SizedBox();
            }),
          ),
        ),
      );

      expect(store.disposeCalls, 0);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      expect(store.disposeCalls, 1);
    });

    testWidgets('of() throws a helpful error with no ancestor scope',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            expect(
              () => OrbitScope.of<CounterStore>(context),
              throwsA(isA<FlutterError>()),
            );
            return const SizedBox();
          }),
        ),
      );
    });

    testWidgets('mutations in a scoped store still reach Orbit.observe',
        (tester) async {
      final received = <OrbitMutation>[];
      final unsubscribe = Orbit.observe((s, m) => received.add(m));

      late CounterStore store;
      await tester.pumpWidget(
        MaterialApp(
          home: OrbitScope<CounterStore>(
            create: () => CounterStore(),
            child: Builder(builder: (context) {
              // Just capture the reference here — mutating during build
              // would race with OrbitScope's own InheritedNotifier
              // subscription and risk a "markNeedsBuild during build"
              // assertion. Mutate after the frame settles instead.
              store = OrbitScope.of<CounterStore>(context, listen: false);
              return const SizedBox();
            }),
          ),
        ),
      );

      store.increment();

      unsubscribe();
      expect(received, hasLength(1));
    });

    testWidgets('maybeOf returns null when no scope is present',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            expect(OrbitScope.maybeOf<CounterStore>(context), isNull);
            return const SizedBox();
          }),
        ),
      );
    });
  });

  group('bug fixes & optimizations', () {
    test('mutate and mutateAsync return action result', () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());

      final val = store.runMutate(() => 42);
      expect(val, 42);

      final asyncVal = await store.runMutateAsync(() async => 99);
      expect(asyncVal, 99);
    });

    test('double disposal on OrbitStore is safe', () {
      final store = CounterStore();
      store.dispose();
      expect(() => store.dispose(), returnsNormally);
    });

    testWidgets(
        'OrbitSelector updates when selector prop changes in parent rebuild',
        (tester) async {
      int multiplier = 2;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            return MaterialApp(
              home: Column(
                children: [
                  OrbitSelector<CounterStore, int>(
                    store: () => CounterStore(),
                    selector: (store) => store.count * multiplier,
                    builder: (context, val) => Text('Value: $val'),
                  ),
                  ElevatedButton(
                    onPressed: () => setState(() => multiplier = 3),
                    child: const Text('Update Multiplier'),
                  ),
                ],
              ),
            );
          },
        ),
      );

      final store = Orbit.read<CounterStore>()!;
      store.increment();
      await tester.pump();
      expect(find.text('Value: 2'), findsOneWidget);

      await tester.tap(find.text('Update Multiplier'));
      await tester.pump();

      expect(find.text('Value: 3'), findsOneWidget);
    });

    test('automatically infers label from caller method name when omitted', () {
      Orbit.debugLogging = true;
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.clearChangeLog();

      store.increment(); // label omitted in increment() method!

      expect(Orbit.changeLog, hasLength(1));
      expect(Orbit.changeLog.single.action, 'increment');
    });

    test(
        'label inference supports JS, Firefox and obfuscated/empty stack traces',
        () {
      final store = Orbit.use<CounterStore>(() => CounterStore());

      // 1. VM stack trace format
      final vmTrace = MockStackTrace(
          '#0      OrbitStore.mutate (package:orbit/src/orbit_store.dart:100:5)\n'
          '#1      CounterStore.increment (package:orbit/example/main.dart:20:10)\n'
          '#2      main (package:orbit/example/main.dart:5:5)');
      expect(store.inferLabelForTest(null, vmTrace), 'increment');

      // 2. Chrome/V8 JS stack trace format
      final chromeTrace = MockStackTrace('Error\n'
          '    at CounterStore.mutate (http://localhost:8080/main.js:200:10)\n'
          '    at CounterStore.increment (http://localhost:8080/main.js:100:5)\n'
          '    at main (http://localhost:8080/main.js:5:2)');
      expect(store.inferLabelForTest(null, chromeTrace), 'increment');

      // 3. Firefox/Safari stack trace format
      final firefoxTrace =
          MockStackTrace('mutate@http://localhost:8080/main.js:200:10\n'
              'increment@http://localhost:8080/main.js:100:5\n'
              'main@http://localhost:8080/main.js:5:2');
      expect(store.inferLabelForTest(null, firefoxTrace), 'increment');

      // 4. Obfuscated or unrecognizable stack trace (should fall back gracefully to null without crashing)
      final obfuscatedTrace = MockStackTrace('wasm-function[1234]:0x123abc');
      expect(store.inferLabelForTest(null, obfuscatedTrace), isNull);

      // 5. Explicit label always overrides stack trace parsing
      expect(store.inferLabelForTest('explicit', vmTrace), 'explicit');
    });

    testWidgets('context.orbit and context.orbitRead access store correctly',
        (tester) async {
      final ref = defineStore(() => CounterStore());

      await tester.pumpWidget(
        MaterialApp(
          home: OrbitScope<CounterStore>(
            create: () => CounterStore(),
            child: Builder(builder: (context) {
              final store = context.orbit<CounterStore>();
              return TextButton(
                onPressed: () =>
                    context.orbitRead<CounterStore>(ref).increment(),
                child: Text('Count: ${store.count}'),
              );
            }),
          ),
        ),
      );

      expect(find.text('Count: 0'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pump();

      expect(find.text('Count: 1'), findsOneWidget);
    });

    testWidgets('storeRef.builder and storeRef.select render properly',
        (tester) async {
      final counterRef = defineStore(() => CounterStore());

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              counterRef.builder(
                builder: (context, store, child) =>
                    Text('Builder: ${store.count}'),
              ),
              counterRef.select<int>(
                selector: (store) => store.doubleCount,
                builder: (context, doubleVal) => Text('Select: $doubleVal'),
              ),
            ],
          ),
        ),
      );

      expect(find.text('Builder: 0'), findsOneWidget);
      expect(find.text('Select: 0'), findsOneWidget);

      counterRef().increment();
      await tester.pump();

      expect(find.text('Builder: 1'), findsOneWidget);
      expect(find.text('Select: 2'), findsOneWidget);
    });

    test(
        'observer exceptions do not break remaining observers or store mutation',
        () {
      bool secondObserverRan = false;

      final unsubscribe1 = Orbit.observe((store, mutation) {
        throw Exception('Observer 1 crashed!');
      });
      final unsubscribe2 = Orbit.observe((store, mutation) {
        secondObserverRan = true;
      });

      final store = Orbit.use<CounterStore>(() => CounterStore());
      expect(() => store.increment(), returnsNormally);
      expect(secondObserverRan, isTrue);

      unsubscribe1();
      unsubscribe2();
    });

    testWidgets('OrbitScope disposes store if init() throws synchronously',
        (tester) async {
      bool disposed = false;

      await tester.pumpWidget(
        OrbitScope<ScopeFailingInitStore>(
          create: () =>
              ScopeFailingInitStore(onDisposeCallback: () => disposed = true),
          child: const SizedBox.shrink(),
        ),
      );

      final dynamic error = tester.takeException();
      expect(error, isA<StateError>());
      expect(disposed, isTrue);
    });
  });

  group('AsyncValue', () {
    test('AsyncValue.data constructor and properties', () {
      const val = AsyncValue.data(42);
      expect(val.isLoading, isFalse);
      expect(val.hasValue, isTrue);
      expect(val.hasError, isFalse);
      expect(val.valueOrNull, 42);
      expect(val.toString(), 'AsyncData(42)');
      expect(val, const AsyncData(42));
      expect(val.hashCode, const AsyncData(42).hashCode);
    });

    test('AsyncValue.loading constructor and properties', () {
      const val = AsyncValue.loading();
      expect(val.isLoading, isTrue);
      expect(val.hasValue, isFalse);
      expect(val.hasError, isFalse);
      expect(val.valueOrNull, isNull);
      expect(val.toString(), 'AsyncLoading()');
      expect(val, const AsyncLoading());
      expect(val.hashCode, const AsyncLoading().hashCode);
    });

    test('AsyncValue.error constructor and properties', () {
      final exception = Exception('fail');
      final stackTrace = StackTrace.current;
      final val = AsyncValue.error(exception, stackTrace);
      expect(val.isLoading, isFalse);
      expect(val.hasValue, isFalse);
      expect(val.hasError, isTrue);
      expect(val.valueOrNull, isNull);
      expect(val.toString(), 'AsyncError(Exception: fail)');
      expect(val, AsyncError(exception, stackTrace));
      expect(val.hashCode, AsyncError(exception, stackTrace).hashCode);
    });

    test('AsyncValue.when maps states correctly', () {
      const loadingVal = AsyncValue<int>.loading();
      expect(
        loadingVal.when(
          data: (d) => 'data $d',
          loading: () => 'loading',
          error: (e, s) => 'error',
        ),
        'loading',
      );

      const dataVal = AsyncValue.data(123);
      expect(
        dataVal.when(
          data: (d) => 'data $d',
          loading: () => 'loading',
          error: (e, s) => 'error',
        ),
        'data 123',
      );

      final errorVal = AsyncValue<int>.error('err');
      expect(
        errorVal.when(
          data: (d) => 'data $d',
          loading: () => 'loading',
          error: (e, s) => 'error $e',
        ),
        'error err',
      );
    });
  });

  group('FutureProvider', () {
    test('resolves future successfully', () async {
      final completer = Completer<String>();
      final provider = FutureProvider<String>(() => completer.future);

      expect(provider.state.isLoading, isTrue);

      Orbit.use<FutureProvider<String>>(() => provider);

      completer.complete('hello');
      await provider.ready;

      expect(provider.state.hasValue, isTrue);
      expect(provider.state.valueOrNull, 'hello');
    });

    test('handles errors and allows refresh()', () async {
      var callCount = 0;
      final provider = FutureProvider<int>(() async {
        callCount++;
        if (callCount == 1) {
          throw StateError('failed first time');
        }
        return 42;
      });

      Orbit.use<FutureProvider<int>>(() => provider);

      await expectLater(provider.ready, throwsStateError);
      expect(provider.state.hasError, isTrue);
      expect(provider.state.isLoading, isFalse);

      await provider.refresh();
      expect(provider.state.hasValue, isTrue);
      expect(provider.state.valueOrNull, 42);
      expect(callCount, 2);
    });

    test('ignores stale concurrent refresh calls', () async {
      final completers = <Completer<int>>[];
      final provider = FutureProvider<int>(() {
        final c = Completer<int>();
        completers.add(c);
        return c.future;
      });

      Orbit.use<FutureProvider<int>>(() => provider);

      final secondRefresh = provider.refresh();

      expect(completers, hasLength(2));

      completers[0].complete(100);
      await Future<void>.delayed(Duration.zero);
      expect(provider.state.isLoading, isTrue);

      completers[1].complete(200);
      await secondRefresh;
      expect(provider.state.valueOrNull, 200);
    });
  });

  group('StreamProvider', () {
    test('subscribes and updates values over time', () async {
      final controller = StreamController<int>();
      final provider = StreamProvider<int>(() => controller.stream);

      Orbit.use<StreamProvider<int>>(() => provider);
      expect(provider.state.isLoading, isTrue);

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      expect(provider.state.valueOrNull, 1);

      controller.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(provider.state.valueOrNull, 2);

      await controller.close();
    });

    test('handles stream errors and cancels on dispose', () async {
      final controller = StreamController<int>();
      final provider = StreamProvider<int>(() => controller.stream);

      Orbit.use<StreamProvider<int>>(() => provider);

      controller.addError('error msg');
      await Future<void>.delayed(Duration.zero);
      expect(provider.state.hasError, isTrue);

      provider.dispose();
      expect(controller.hasListener, isFalse);

      await controller.close();
    });

    test('supports refresh() to re-subscribe', () async {
      var callCount = 0;
      final provider = StreamProvider<int>(() {
        callCount++;
        return Stream.value(callCount);
      });

      Orbit.use<StreamProvider<int>>(() => provider);
      await Future<void>.delayed(Duration.zero);
      expect(provider.state.valueOrNull, 1);

      provider.refresh();
      expect(provider.state.isLoading, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(provider.state.valueOrNull, 2);
      expect(callCount, 2);
    });

    test('handles synchronous stream factory errors', () async {
      final provider = StreamProvider<int>(() {
        throw StateError('sync stream error');
      });

      Orbit.use<StreamProvider<int>>(() => provider);
      expect(provider.state.hasError, isTrue);
      expect(provider.state.toString(), contains('sync stream error'));
    });
  });

  group('ComputedStore', () {
    test('computes initial state and reacts to updates', () {
      final source = defineStore(() => CounterStore());
      final computed = defineStore(() => ComputedStore<int>((watch) {
            final src = watch(source);
            return src.count * 10;
          }));

      expect(computed().state, 0);

      source().increment();
      expect(computed().state, 10);

      source().increment();
      expect(computed().state, 20);
    });

    test('cleans up dependency listeners when disposed', () {
      final source = defineStore(() => CounterStore());
      final computed = ComputedStore<int>((watch) {
        final src = watch(source);
        return src.count;
      });

      Orbit.use<ComputedStore<int>>(() => computed);
      expect(computed.state, 0);

      computed.dispose();

      source().increment();
      expect(computed.state, 0);
    });

    test('correctly records diffs in Orbit change log', () {
      Orbit.debugLogging = true;
      final source = defineStore(() => CounterStore());
      final computed = defineStore(() => ComputedStore<int>((watch) {
            final src = watch(source);
            return src.count * 5;
          }));

      computed();
      Orbit.clearChangeLog();

      source().increment();

      expect(Orbit.changeLog, hasLength(2));
      final computedChange = Orbit.changeLog.first;
      expect(computedChange.store, same(computed()));
      expect(computedChange.action, 'recompute');
      expect(computedChange.diff, {'state': (0, 5)});
    });

    test('handles dependency reset/override correctly', () {
      final source = defineStore(() => CounterStore());
      final computed = defineStore(() => ComputedStore<int>((watch) {
            final src = watch(source);
            return src.count;
          }));

      expect(computed().state, 0);

      source().increment();
      expect(computed().state, 1);

      Orbit.reset<CounterStore>();

      expect(computed().state, 0);

      source().increment();
      expect(computed().state, 1);
    });

    test(
        'handles conditional dependencies dynamically and does not leak or fail',
        () {
      final flagStore = defineStore(() => FlagStore());
      final storeA = defineStore(() => CounterStoreA());
      final storeB = defineStore(() => CounterStoreB());

      var computeCount = 0;
      final computed = defineStore(() => ComputedStore<int>((watch) {
            computeCount++;
            final useA = watch(flagStore).count > 0;
            if (useA) {
              return watch(storeA).count;
            } else {
              return watch(storeB).count;
            }
          }));

      expect(computed().state, 0);
      expect(computeCount, 1);

      // Changing storeA (not currently watched) should NOT trigger recompute
      storeA().increment();
      expect(computed().state, 0);
      expect(computeCount, 1);

      // Changing storeB (currently watched) should trigger recompute
      storeB().increment();
      expect(computed().state, 1);
      expect(computeCount, 2);

      // Flip flag: flagStore.count = 1 -> now uses storeA
      flagStore().increment();
      expect(computed().state, 1); // storeA has count 1
      expect(computeCount, 3);

      // Changing storeB (no longer watched) should NOT trigger recompute
      storeB().increment();
      expect(computed().state, 1);
      expect(computeCount, 3);

      // Changing storeA (now watched) should trigger recompute
      storeA().increment();
      expect(computed().state, 2);
      expect(computeCount, 4);
    });
  });

  group('OrbitStore.watch', () {
    test('subscribes to updates and unsubscribes on dispose', () {
      final source = defineStore(() => CounterStore());
      var triggerCount = 0;
      var lastValue = -1;

      final watcher = Orbit.use<WatcherStore>(() => WatcherStore(source, (val) {
            triggerCount++;
            lastValue = val;
          }));

      source().increment();
      expect(triggerCount, 1);
      expect(lastValue, 1);

      watcher.dispose();

      source().increment();
      expect(triggerCount, 1);
    });
  });

  group('OrbitStore.debounce', () {
    test('postpones execution and runs only once for consecutive calls',
        () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var callCount = 0;

      store.debounce('test_deb', const Duration(milliseconds: 10), () {
        callCount++;
      });
      store.debounce('test_deb', const Duration(milliseconds: 10), () {
        callCount++;
      });
      store.debounce('test_deb', const Duration(milliseconds: 10), () {
        callCount++;
      });

      expect(callCount, 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(callCount, 1);
    });

    test('cancels timer and does not fire if store is disposed', () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var fired = false;

      store.debounce('test_deb', const Duration(milliseconds: 10), () {
        fired = true;
      });

      store.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, isFalse);
    });

    test('reports async errors to FlutterError', () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      try {
        store.debounce('test_deb', const Duration(milliseconds: 10), () {
          throw StateError('debounced error');
        });

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errors, hasLength(1));
        expect(errors.first.exception, isA<StateError>());
        expect(errors.first.context.toString(),
            contains('inside debounced action'));
      } finally {
        FlutterError.onError = originalOnError;
      }
    });
  });

  group('OrbitStore.throttle', () {
    test('executes immediately and rate-limits subsequent calls', () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var callCount = 0;

      store.throttle('test_throt', const Duration(milliseconds: 10), () {
        callCount++;
      });
      store.throttle('test_throt', const Duration(milliseconds: 10), () {
        callCount++;
      });
      store.throttle('test_throt', const Duration(milliseconds: 10), () {
        callCount++;
      });

      expect(callCount, 1);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      store.throttle('test_throt', const Duration(milliseconds: 10), () {
        callCount++;
      });
      expect(callCount, 2);
    });

    test('reports synchronous and asynchronous errors to FlutterError',
        () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      try {
        store.throttle('test_throt_err1', const Duration(milliseconds: 10), () {
          throw StateError('throttled sync error');
        });

        store.throttle('test_throt_err2', const Duration(milliseconds: 10),
            () async {
          throw StateError('throttled async error');
        });

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errors, hasLength(2));
        expect(
            errors[0].exception.toString(), contains('throttled sync error'));
        expect(
            errors[1].exception.toString(), contains('throttled async error'));
      } finally {
        FlutterError.onError = originalOnError;
      }
    });

    test('cancels active timers and does not fire or leak if store is disposed',
        () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var fired = false;

      // First call executes immediately (leading edge)
      store.throttle('test_throt', const Duration(milliseconds: 10), () {
        fired = true;
      });
      expect(fired, isTrue);

      fired = false;
      store.dispose();

      // Subsequent call after dispose should not fire
      store.throttle('test_throt', const Duration(milliseconds: 10), () {
        fired = true;
      });
      expect(fired, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, isFalse);
    });
  });

  group('Compile-time Safety Lookups', () {
    testWidgets(
        'OrbitStoreRef.of falls back to global singleton when no scope exists',
        (tester) async {
      final counterStore = defineStore(() => CounterStore());

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            final store = counterStore.of(context);
            return Text('Count: ${store.count}');
          },
        ),
      ));

      expect(find.text('Count: 0'), findsOneWidget);
    });

    testWidgets(
        'OrbitStoreRef.of resolves to scoped store and listens to changes',
        (tester) async {
      final counterStore = defineStore(() => CounterStore());

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: OrbitScope<CounterStore>(
          create: () => CounterStore(),
          child: Builder(
            builder: (context) {
              final store = counterStore.of(context);
              return Text('Count: ${store.count}');
            },
          ),
        ),
      ));

      expect(find.text('Count: 0'), findsOneWidget);

      final scopedStore =
          OrbitScope.of<CounterStore>(tester.element(find.byType(Builder)));
      scopedStore.increment();
      await tester.pump();

      expect(find.text('Count: 1'), findsOneWidget);
    });

    testWidgets(
        'context.orbit(storeRef) and context.orbitRead(storeRef) work correctly',
        (tester) async {
      final counterStore = defineStore(() => CounterStore());

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: OrbitScope<CounterStore>(
          create: () => CounterStore(),
          child: Builder(
            builder: (context) {
              final store = context.orbit(counterStore);
              return GestureDetector(
                onTap: () {
                  final readStore = context.orbitRead(counterStore);
                  readStore.increment();
                },
                child: Text('Count: ${store.count}'),
              );
            },
          ),
        ),
      ));

      expect(find.text('Count: 0'), findsOneWidget);

      await tester.tap(find.text('Count: 0'));
      await tester.pump();

      expect(find.text('Count: 1'), findsOneWidget);
    });
  });
}

class ScopeFailingInitStore extends OrbitStore {
  final VoidCallback onDisposeCallback;

  ScopeFailingInitStore({required this.onDisposeCallback});

  @override
  FutureOr<void> init() {
    throw StateError('Init failed synchronously');
  }

  @override
  void onDispose() => onDisposeCallback();
}

class WatcherStore extends OrbitStore {
  WatcherStore(this.sourceRef, this.onTrigger);
  final OrbitStoreRef<CounterStore> sourceRef;
  final void Function(int value) onTrigger;

  @override
  void init() {
    watch(sourceRef, (store) {
      onTrigger(store.count);
    });
  }
}

class MockStackTrace implements StackTrace {
  MockStackTrace(this._trace);
  final String _trace;
  @override
  String toString() => _trace;
}
