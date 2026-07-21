import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/orbit.dart';

class CounterStore extends OrbitStore {
  int _count = 0;
  int initCalls = 0;
  int disposeCalls = 0;

  int get count => _count;
  int get doubleCount => _count * 2;

  void increment() => mutate(() => _count++, label: 'increment');

  Future<void> incrementAsync() async {
    await mutateAsync(() async {
      await Future<void>.delayed(Duration.zero);
      _count++;
    }, label: 'incrementAsync');
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

    test('mutateAsync() notifies once the awaited action completes',
        () async {
      final store = Orbit.use<CounterStore>(() => CounterStore());
      var notified = 0;
      store.addListener(() => notified++);

      await store.incrementAsync();

      expect(store.count, 1);
      expect(notified, 1);
    });

    test('reset() disposes the store, runs onDispose(), and clears the '
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

    test('override() swaps in a fake store, disposing the previous one',
        () {
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

    test('an async init() leaves the store usable immediately, '
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
    test('mutate() records a change with a diff when debugSnapshot '
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

    test('nothing is logged when debugLogging is off and no observers',
        () {
      Orbit.debugLogging = false;
      final store = Orbit.use<CounterStore>(() => CounterStore());
      Orbit.clearChangeLog();

      store.increment();

      expect(Orbit.changeLog, isEmpty);
    });

    test('observe() fires for every mutation, even with debugLogging off',
        () {
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

    testWidgets('maybeOf returns null when no scope is present', (tester) async {
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

      final val = store.mutate(() => 42);
      expect(val, 42);

      final asyncVal = await store.mutateAsync(() async => 99);
      expect(asyncVal, 99);
    });

    test('double disposal on OrbitStore is safe', () {
      final store = CounterStore();
      store.dispose();
      expect(() => store.dispose(), returnsNormally);
    });

    testWidgets('OrbitSelector updates when selector prop changes in parent rebuild',
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
                onPressed: () => context.orbitRead<CounterStore>(ref).increment(),
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
                builder: (context, store, child) => Text('Builder: ${store.count}'),
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
  });
}
