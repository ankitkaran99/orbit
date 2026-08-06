import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_state/orbit.dart';

class _PlainStore extends OrbitStore {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);
}

class _UndoableCounterStore extends OrbitStore with Undoable {
  int _count = 0;
  int get count => _count;

  void increment() => mutate(() => _count++);

  void incrementThenThrow() => mutate(() {
        _count++;
        throw StateError('sync error');
      });

  Future<void> incrementAsync() async {
    await mutate(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      _count++;
    });
  }

  Future<void> incrementThenThrowAsync() async {
    await mutate(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      _count++;
      throw StateError('async error');
    });
  }

  Future<void> fetchAndAdd(int amount) async {
    await mutateAsync<int>(
      action: () async => amount,
      apply: (res) => _count += res,
    );
  }

  @override
  Map<String, Object?> snapshot() => {'count': _count};

  @override
  void restore(Map<String, Object?> state) {
    _count = state['count'] as int;
  }
}

void main() {
  tearDown(() {
    Orbit.resetAll();
    Orbit.undoStackLimit = 50;
  });

  group('Undoable & Orbit.undo()/redo()', () {
    test(
        'Mutate Undoable store -> Orbit.undo() restores pre-mutation state & notifies listeners',
        () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());
      var notifications = 0;
      store.addListener(() => notifications++);

      expect(store.count, 0);
      expect(Orbit.canUndo, isFalse);

      store.increment();

      expect(store.count, 1);
      expect(Orbit.canUndo, isTrue);
      expect(notifications, 1);

      Orbit.undo();

      expect(store.count, 0);
      expect(notifications, 2,
          reason:
              'undo() must go through mutate()/restore() and notify listeners');
      expect(Orbit.canUndo, isFalse);
      expect(Orbit.canRedo, isTrue);
    });

    test('Orbit.redo() after Orbit.undo() restores post-mutation state', () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());
      store.increment(); // count: 1
      expect(store.count, 1);

      Orbit.undo(); // count: 0
      expect(store.count, 0);
      expect(Orbit.canRedo, isTrue);

      Orbit.redo(); // count: 1
      expect(store.count, 1);
      expect(Orbit.canRedo, isFalse);
      expect(Orbit.canUndo, isTrue);
    });

    test('New mutate() call after undo() clears redo stack', () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());
      store.increment(); // count: 1
      Orbit.undo(); // count: 0

      expect(Orbit.canRedo, isTrue);

      store.increment(); // new mutation: count: 1

      expect(Orbit.canRedo, isFalse,
          reason: 'fresh mutation invalidates redo history');

      // redo() should be a no-op
      Orbit.redo();
      expect(store.count, 1);
    });

    test(
        'Async mutate(): undo entry pushed only after awaited Future completes',
        () async {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());

      final future = store.incrementAsync();

      expect(Orbit.canUndo, isFalse,
          reason: 'undo entry should not be pushed before async work finishes');

      await future;

      expect(store.count, 1);
      expect(Orbit.canUndo, isTrue);

      Orbit.undo();
      expect(store.count, 0);
    });

    test('mutateAsync() produces exactly 1 undo entry per call', () async {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());

      await store.fetchAndAdd(5);

      expect(store.count, 5);
      expect(Orbit.canUndo, isTrue);

      Orbit.undo();
      expect(store.count, 0);
      expect(Orbit.canUndo, isFalse,
          reason: 'exactly 1 undo entry should exist from mutateAsync call');
    });

    test(
        'Throwing mutation (sync) pushes partial state undo entry and rethrows',
        () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());

      expect(() => store.incrementThenThrow(), throwsStateError);

      expect(store.count, 1, reason: 'partial state change stuck before throw');
      expect(Orbit.canUndo, isTrue,
          reason: 'undo entry pushed even for throwing mutation');

      Orbit.undo();
      expect(store.count, 0);
    });

    test(
        'Rejecting mutation (async) pushes partial state undo entry and rethrows',
        () async {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());

      await expectLater(store.incrementThenThrowAsync(), throwsStateError);

      expect(store.count, 1);
      expect(Orbit.canUndo, isTrue);

      Orbit.undo();
      expect(store.count, 0);
    });

    test('Reentrancy guard: calling Orbit.undo() does NOT push new undo entry',
        () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());
      store.increment(); // count: 1

      expect(Orbit.canUndo, isTrue);

      Orbit.undo(); // count: 0

      expect(Orbit.canUndo, isFalse,
          reason: 'undo action itself must not push onto undo stack');
      expect(Orbit.canRedo, isTrue);
    });

    test('undoStackLimit drops oldest entries when limit exceeded', () {
      Orbit.undoStackLimit = 3;
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());

      store.increment(); // count: 1
      store.increment(); // count: 2
      store.increment(); // count: 3
      store.increment(); // count: 4 (oldest count: 1 entry dropped)

      expect(store.count, 4);

      Orbit.undo(); // back to 3
      expect(store.count, 3);
      Orbit.undo(); // back to 2
      expect(store.count, 2);
      Orbit.undo(); // back to 1
      expect(store.count, 1);

      expect(Orbit.canUndo, isFalse,
          reason: 'only 3 undo entries retained due to limit of 3');
    });

    test('Orbit.undo() / redo() on disposed store is safe no-op', () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());
      store.increment(); // count: 1

      Orbit.reset<_UndoableCounterStore>(); // disposes store

      expect(Orbit.canUndo, isTrue);

      // Calling undo on disposed store should safely drop entry without crashing
      Orbit.undo();

      expect(Orbit.canRedo, isFalse,
          reason: 'disposed entry dropped without pushing to redo stack');
    });

    test('Orbit.resetAll() clears both undo and redo stacks', () {
      final store =
          Orbit.use<_UndoableCounterStore>(() => _UndoableCounterStore());
      store.increment();
      Orbit.undo();

      expect(Orbit.canRedo, isTrue);

      Orbit.resetAll();

      expect(Orbit.canUndo, isFalse);
      expect(Orbit.canRedo, isFalse);
    });

    test('Plain non-Undoable store mutations never touch undo stack', () {
      final plain = Orbit.use<_PlainStore>(() => _PlainStore());
      plain.increment();

      expect(plain.count, 1);
      expect(Orbit.canUndo, isFalse,
          reason: 'non-Undoable store does not push undo entries');
    });
  });
}
