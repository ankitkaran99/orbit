import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_state/orbit.dart';

class _StoreA extends OrbitStore {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);
}

class _StoreB extends OrbitStore {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);
}

class _StoreC extends OrbitStore {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);
}

void main() {
  tearDown(() {
    Orbit.resetAll();
    OrbitBatchWatchdog.warnAfter = const Duration(seconds: 5);
    OrbitBatchWatchdog.onWarning = print;
  });

  group('Orbit.batch() and store.batch()', () {
    test(
        '30 sequential mutate() calls on one store inside Orbit.batch() -> exactly 1 notification',
        () {
      final store = Orbit.use<_StoreA>(() => _StoreA());
      var notifications = 0;
      store.addListener(() => notifications++);

      Orbit.batch(() {
        for (var i = 0; i < 30; i++) {
          store.increment();
          expect(notifications, 0,
              reason: 'Notification should be deferred during batch');
        }
      });

      expect(store.count, 30);
      expect(notifications, 1,
          reason:
              'Exactly 1 notification should fire after global batch closes');
    });

    test(
        'Mutations across 3 different stores inside Orbit.batch() -> exactly 3 notifications (one per store), all after batch closes',
        () {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      final storeB = Orbit.use<_StoreB>(() => _StoreB());
      final storeC = Orbit.use<_StoreC>(() => _StoreC());

      var notifA = 0;
      var notifB = 0;
      var notifC = 0;

      storeA.addListener(() => notifA++);
      storeB.addListener(() => notifB++);
      storeC.addListener(() => notifC++);

      Orbit.batch(() {
        storeA.increment();
        storeA.increment();
        storeB.increment();
        storeC.increment();
        storeC.increment();

        expect(notifA, 0);
        expect(notifB, 0);
        expect(notifC, 0);
      });

      expect(notifA, 1);
      expect(notifB, 1);
      expect(notifC, 1);
      expect(storeA.count, 2);
      expect(storeB.count, 1);
      expect(storeC.count, 2);
    });

    test(
        'store.batch() wrapping mutations on that store only -> unaffected stores notify immediately',
        () {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      final storeB = Orbit.use<_StoreB>(() => _StoreB());

      var notifA = 0;
      var notifB = 0;

      storeA.addListener(() => notifA++);
      storeB.addListener(() => notifB++);

      storeA.batch(() {
        storeA.increment();
        storeA.increment();
        expect(notifA, 0, reason: 'storeA notification deferred');

        storeB.increment();
        expect(notifB, 1,
            reason:
                'unaffected storeB notifies immediately during storeA batch');
      });

      expect(notifA, 1,
          reason: 'storeA notifies once when storeA.batch closes');
      expect(notifB, 1);
    });

    test(
        'store.batch() nested inside Orbit.batch() -> store notification delivered exactly once when outer global batch closes',
        () {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      var notifA = 0;
      storeA.addListener(() => notifA++);

      Orbit.batch(() {
        storeA.batch(() {
          storeA.increment();
          storeA.increment();
        });

        expect(notifA, 0,
            reason:
                'storeA notification should NOT fire when inner storeA.batch closes because outer Orbit.batch is still open');
      });

      expect(notifA, 1,
          reason:
              'storeA notification delivered exactly once when outer Orbit.batch closes');
    });

    test(
        'Orbit.batch() nested inside Orbit.batch() -> only outermost closing triggers flush',
        () {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      final storeB = Orbit.use<_StoreB>(() => _StoreB());

      var notifA = 0;
      var notifB = 0;

      storeA.addListener(() => notifA++);
      storeB.addListener(() => notifB++);

      Orbit.batch(() {
        storeA.increment();

        Orbit.batch(() {
          storeB.increment();
          expect(notifA, 0);
          expect(notifB, 0);
        });

        expect(notifA, 0, reason: 'inner batch close is a no-op');
        expect(notifB, 0, reason: 'inner batch close is a no-op');
      });

      expect(notifA, 1);
      expect(notifB, 1);
    });

    test(
        'Async batch: notification happens only after awaited work completes, not before',
        () async {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      var notifA = 0;
      storeA.addListener(() => notifA++);

      final future = Orbit.batch(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        storeA.increment();
        expect(notifA, 0);
      });

      expect(notifA, 0, reason: 'not notified before async batch completes');

      await future;

      expect(notifA, 1, reason: 'notified only after async batch completes');
      expect(storeA.count, 1);
    });

    test('Exception inside sync batch -> batch depth returns to 0 and rethrows',
        () {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      var notifA = 0;
      storeA.addListener(() => notifA++);

      expect(
        () => Orbit.batch(() {
          storeA.increment();
          throw StateError('sync batch boom');
        }),
        throwsStateError,
      );

      expect(notifA, 1,
          reason: 'pending notification flushed even on exception');

      // Verify batch depth returned to 0: subsequent mutations notify immediately
      storeA.increment();
      expect(notifA, 2,
          reason:
              'batch depth returned to 0, next mutation notifies immediately');
    });

    test(
        'Exception inside async batch -> batch depth returns to 0 and rethrows',
        () async {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());
      var notifA = 0;
      storeA.addListener(() => notifA++);

      await expectLater(
        Orbit.batch(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          storeA.increment();
          throw StateError('async batch boom');
        }),
        throwsStateError,
      );

      expect(notifA, 1,
          reason: 'pending notification flushed on async exception');

      storeA.increment();
      expect(notifA, 2,
          reason:
              'batch depth returned to 0, next mutation notifies immediately');
    });

    test('Orbit.batch returns sync action result', () {
      final result = Orbit.batch(() => 42);
      expect(result, 42);
    });

    test('Orbit.batch returns async action result', () async {
      final result = await Orbit.batch(() async => 99);
      expect(result, 99);
    });

    test('store.batch returns sync and async action results', () async {
      final storeA = Orbit.use<_StoreA>(() => _StoreA());

      final syncRes = storeA.batch(() => 'hello');
      expect(syncRes, 'hello');

      final asyncRes = await storeA.batch(() async => 'world');
      expect(asyncRes, 'world');
    });
  });

  group('OrbitBatchWatchdog', () {
    test('triggers onWarning in debug mode when batch left open past warnAfter',
        () async {
      OrbitBatchWatchdog.warnAfter = const Duration(milliseconds: 30);
      String? warningMsg;
      OrbitBatchWatchdog.onWarning = (msg) {
        warningMsg = msg;
      };

      // Open a batch and leave it unclosed for a bit
      final completer = Completer<void>();
      Orbit.batch(() async {
        await completer.future;
      });

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(warningMsg, isNotNull);
      expect(warningMsg, contains('Orbit batch "Orbit.batch" has been open'));
      expect(warningMsg, contains('Hint: Keep batch bodies fast'));

      completer.complete();
    });

    test('batch closed before warnAfter does not trigger onWarning', () async {
      OrbitBatchWatchdog.warnAfter = const Duration(milliseconds: 100);
      var warningCount = 0;
      OrbitBatchWatchdog.onWarning = (_) => warningCount++;

      await Orbit.batch(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(warningCount, 0,
          reason: 'Warning should not be triggered when batch closes in time');
    });
  });
}
