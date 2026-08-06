part of '../orbit.dart';

/// Called for every mutation, on every store, once registered via
/// [Orbit.observe]. Gets both the store (already reflecting the new
/// state) and the [OrbitMutation] describing what happened.
typedef OrbitObserver = void Function(OrbitStore store, OrbitMutation mutation);

/// Global registry of store singletons — the same role Pinia plays when
/// it keeps one live instance of each store for the whole app, reachable
/// from anywhere without threading a `BuildContext` through.
///
/// You usually won't call this directly; `OrbitBuilder` and
/// `OrbitSelector` call [use] for you under the hood. It's public
/// so you can also read or act on a store from outside the widget tree —
/// services, background isolate callbacks, tests, etc.
class Orbit {
  Orbit._();

  static final Map<Type, OrbitStore> _stores = {};
  static final Set<OrbitStore> _scopedStores = Set<OrbitStore>.identity();

  static void _registerScopedStore(OrbitStore store) {
    _scopedStores.add(store);
    _registerServiceExtension();
  }

  static void _unregisterScopedStore(OrbitStore store) {
    _scopedStores.remove(store);
    _purgeUndoEntriesFor(store);
  }

  static bool _serviceExtensionRegistered = false;

  static void _registerServiceExtension() {
    if (_serviceExtensionRegistered) return;
    _serviceExtensionRegistered = true;
    try {
      developer.registerExtension('ext.orbit.getStores',
          (method, parameters) async {
        final Map<String, dynamic> storesData = {};
        for (final entry in _stores.entries) {
          final typeName = entry.key.toString();
          final store = entry.value;
          Object? snapshot;
          try {
            snapshot = _jsonSafe(store.snapshot());
          } catch (error) {
            snapshot = {'_error': 'snapshot() threw: $error'};
          }
          storesData[typeName] = {
            'state': snapshot ?? {},
            'isReady': store.isReady,
            'listeners': store._listenerCount,
            'isScoped': false,
          };
        }

        for (final store in _scopedStores) {
          final typeName = store.runtimeType.toString();
          final idHex = identityHashCode(store).toRadixString(16);
          final displayName = '$typeName (#$idHex)';

          Object? snapshot;
          try {
            snapshot = _jsonSafe(store.snapshot());
          } catch (error) {
            snapshot = {'_error': 'snapshot() threw: $error'};
          }

          storesData[displayName] = {
            'state': snapshot ?? {},
            'isReady': store.isReady,
            'listeners': store._listenerCount,
            'isScoped': true,
            'instanceId': idHex,
            'baseType': typeName,
          };
        }

        try {
          return developer.ServiceExtensionResponse.result(jsonEncode({
            'stores': storesData,
          }));
        } catch (error) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            'Failed to encode Orbit store state: $error',
          );
        }
      });
    } catch (_) {}
  }

  /// Recursively coerces a [OrbitStore.snapshot] result into JSON-safe values,
  /// falling back to [Object.toString] for anything [jsonEncode] can't
  /// handle on its own.
  static Object? _jsonSafe(Object? value) {
    if (value == null || value is num || value is String || value is bool) {
      return value;
    }
    if (value is Map) {
      return value.map((key, v) => MapEntry(key.toString(), _jsonSafe(v)));
    }
    if (value is Iterable) {
      return value.map(_jsonSafe).toList();
    }
    try {
      jsonEncode(value);
      return value;
    } catch (_) {
      return value.toString();
    }
  }

  /// Exposed helper for testing [_jsonSafe] directly.
  @visibleForTesting
  static Object? jsonSafeForTest(Object? value) => _jsonSafe(value);

  // ---- Global Batching -------------------------------------------

  static int _globalBatchDepth = 0;
  static final Set<OrbitStore> _globalPendingStores =
      HashSet<OrbitStore>.identity();
  static Timer? _globalWatchdogTimer;

  /// Runs [fn] inside a global batch.
  ///
  /// Any store mutated while the batch is open has its `notifyListeners()` deferred.
  /// Once the outermost global batch closes, all affected stores are deduped and flushed
  /// exactly once.
  static FutureOr<T> batch<T>(
    FutureOr<T> Function() fn, {
    String? label,
  }) {
    final effectiveLabel = label ?? 'Orbit.batch';
    _openGlobalBatch(effectiveLabel);

    try {
      final result = fn();
      if (result is Future) {
        return (result as Future).whenComplete(() {
          _closeGlobalBatch();
        }) as FutureOr<T>;
      }
      _closeGlobalBatch();
      return result;
    } catch (error) {
      _closeGlobalBatch();
      rethrow;
    }
  }

  static void _openGlobalBatch(String label) {
    _globalBatchDepth++;
    if (_globalBatchDepth == 1) {
      if (kDebugMode) {
        final trace = StackTrace.current;
        _globalWatchdogTimer = Timer(OrbitBatchWatchdog.warnAfter, () {
          final message = 'WARNING: Orbit batch "$label" has been open for '
              'longer than ${OrbitBatchWatchdog.warnAfter.inSeconds} seconds.\n'
              'Batch opened at:\n$trace\n'
              'Hint: Keep batch bodies fast. Slow async work belongs inside '
              'mutateAsync\'s action parameter, not inside a batch body.';
          OrbitBatchWatchdog.onWarning(message);
        });
      }
    }
  }

  static void _closeGlobalBatch() {
    if (_globalBatchDepth <= 0) return;
    _globalBatchDepth--;
    if (_globalBatchDepth == 0) {
      _globalWatchdogTimer?.cancel();
      _globalWatchdogTimer = null;

      if (_globalPendingStores.isNotEmpty) {
        final pending = List<OrbitStore>.from(_globalPendingStores);
        _globalPendingStores.clear();

        for (final store in pending) {
          store._scopedPendingNotify = false;
          if (!store._disposed) {
            store._dispatchNotify();
          }
        }
      }
    }
  }

  // ---- Undo / Redo Stacks -------------------------------------------

  /// Maximum number of undo steps retained in history (default 50).
  static int undoStackLimit = 50;

  static bool _isRestoring = false;
  static final List<OrbitUndoEntry> _undoStack = [];
  static final List<OrbitUndoEntry> _redoStack = [];

  /// Whether there is at least one mutation that can be undone.
  static bool get canUndo => _undoStack.isNotEmpty;

  /// Whether there is at least one undone mutation that can be redone.
  static bool get canRedo => _redoStack.isNotEmpty;

  /// Internal — called only from Undoable.mutate().
  static void _pushUndo(OrbitUndoEntry entry) {
    if (_isRestoring) return;
    _undoStack.add(entry);
    if (_undoStack.length > undoStackLimit) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Removes any undo/redo entries referencing [store]. Called whenever a
  /// store is individually disposed (`reset`, `override`, or a scoped
  /// store leaving the tree) so a dead store isn't held onto by the
  /// stacks — `undo()`/`redo()` already handle a disposed entry safely if
  /// encountered lazily, but there's no reason to keep it around until
  /// then when we already know at dispose time.
  static void _purgeUndoEntriesFor(OrbitStore store) {
    if (_undoStack.isEmpty && _redoStack.isEmpty) return;
    _undoStack.removeWhere((entry) => identical(entry.store, store));
    _redoStack.removeWhere((entry) => identical(entry.store, store));
  }

  /// Reverts the most recent mutation across all [Undoable] stores.
  ///
  /// If the store's [Undoable.restore] override throws, that's surfaced as
  /// a normal failed mutation (recorded in [Orbit.changeLog] /
  /// [Orbit.observe] with label `'undo'`, same as any other throwing
  /// `mutate()` call) and rethrown to the caller. The entry is popped
  /// before [Undoable.restore] runs and is deliberately NOT restored to
  /// either stack on failure — [restore] bugs are deterministic, so
  /// retrying the same entry would just fail the same way again, and
  /// keeping a known-broken entry on top of the stack would permanently
  /// block undoing anything older underneath it. Dropping it lets the
  /// next `undo()` call reach the next, presumably-good entry instead.
  static void undo() {
    if (_undoStack.isEmpty) return;
    final entry = _undoStack.removeLast();
    if (entry.store._disposed) return;

    _isRestoring = true;
    try {
      entry.store.mutate(
        () => (entry.store as Undoable).restore(entry.before),
        label: 'undo',
      );
      _redoStack.add(entry);
    } finally {
      _isRestoring = false;
    }
  }

  /// Re-applies the most recently undone mutation.
  ///
  /// Same failure handling as [undo]: a throwing [Undoable.restore]
  /// surfaces as a normal failed, logged mutation and the entry is
  /// dropped rather than retried, for the same reason.
  static void redo() {
    if (_redoStack.isEmpty) return;
    final entry = _redoStack.removeLast();
    if (entry.store._disposed) return;

    _isRestoring = true;
    try {
      entry.store.mutate(
        () => (entry.store as Undoable).restore(entry.after),
        label: 'redo',
      );
      _undoStack.add(entry);
      if (_undoStack.length > undoStackLimit) {
        _undoStack.removeAt(0);
      }
    } finally {
      _isRestoring = false;
    }
  }

  // ---- Debugging & middleware -------------------------------------

  /// Whether mutations are printed to the console and recorded in
  /// [changeLog]. Defaults to `kDebugMode`, so there's no console noise
  /// or retained history in release builds unless you turn this on
  /// explicitly. This does *not* gate [observe] — observers registered
  /// via [observe] always run, in every build mode, since they're meant
  /// to power things like persistence and analytics, not just dev-time
  /// logging.
  static bool debugLogging = kDebugMode;

  static const int _maxLogEntries = 200;
  static final ListQueue<OrbitMutation> _log = ListQueue<OrbitMutation>();
  static final List<OrbitObserver> _observers = [];

  static bool get _hasObservers => _observers.isNotEmpty;

  /// The most recent mutations across every store, oldest first, capped
  /// at the last 200. Only populated while [debugLogging] is on. Useful
  /// to inspect in a debugger, print in a bug report, or render in your
  /// own debug overlay.
  static List<OrbitMutation> get changeLog => List.unmodifiable(_log);

  /// Registers [observer] to run after every mutation, on every store —
  /// mutation middleware, in the spirit of Pinia's `$onAction`. Enables
  /// logging, analytics, or persistence without touching store code:
  ///
  /// ```dart
  /// final unsubscribe = Orbit.observe((store, mutation) {
  ///   analytics.log(mutation.action ?? store.runtimeType.toString());
  /// });
  /// ```
  ///
  /// Returns a function that removes the observer when called.
  static void Function() observe(OrbitObserver observer) {
    _observers.add(observer);
    return () => _observers.remove(observer);
  }

  /// Clears [changeLog]. Mainly useful between test cases.
  static void clearChangeLog() => _log.clear();

  static void _notify(OrbitStore store, OrbitMutation mutation) {
    if (debugLogging) {
      _log.addLast(mutation);
      if (_log.length > _maxLogEntries) _log.removeFirst();
      debugPrint(mutation.toString());
    }
    // Fire postEvent so the VSCode/DevTools extension receives
    // orbit:state-changed events. Skipped in release builds — no VM service
    // client can attach there anyway, and the map allocation on every mutation
    // is unnecessary overhead in production.
    if (!kReleaseMode) {
      try {
        final typeName = store.runtimeType.toString();
        final idHex = identityHashCode(store).toRadixString(16);
        final storeKey = Orbit._scopedStores.contains(store)
            ? '$typeName (#$idHex)'
            : typeName;

        developer.postEvent('orbit:state-changed', {
          'store': typeName,
          'storeKey': storeKey,
          'action': mutation.action,
          // Reuse the snapshot mutate() already took instead of
          // calling the (potentially expensive) snapshot() a 3rd time.
          'state': mutation.after ?? {},
        });
      } catch (_) {}
    }

    if (_observers.isEmpty) return;
    // Iterate a copy: an observer that (un)registers another observer
    // mid-callback shouldn't crash or skip entries.
    for (final observer in List.of(_observers)) {
      try {
        observer(store, mutation);
      } catch (exception, stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: exception,
          stack: stackTrace,
          library: 'orbit',
          context: ErrorDescription('while handling Orbit observer'),
        ));
      }
    }
  }

  // ---- Store registry -----------------------------------------------

  /// Returns the singleton instance of store [T], creating it via
  /// [create] the first time it's requested. Every later call — from
  /// any widget, anywhere — returns that same instance.
  static T use<T extends OrbitStore>(T Function() create) {
    _registerServiceExtension();
    final existing = _stores[T];
    if (existing != null) return existing as T;
    final store = create();
    _stores[T] = store;
    try {
      store._runInit();
    } catch (_) {
      // A synchronous throw from init() — don't leave a broken store
      // in the registry; the next use<T>() call gets a clean retry.
      _stores.remove(T);
      store.dispose();
      rethrow;
    }
    return store;
  }

  /// Returns the existing instance of store [T], or `null` if it hasn't
  /// been created yet. Useful when you want to read a store without
  /// accidentally instantiating it.
  static T? read<T extends OrbitStore>() => _stores[T] as T?;

  /// Registers [instance] as the singleton for store [T], replacing (and
  /// disposing) any existing one. Mainly for widget tests, to swap in a
  /// fake/mock store before pumping the widget under test:
  ///
  /// ```dart
  /// setUp(() => Orbit.override<CounterStore>(FakeCounterStore()));
  /// ```
  static void override<T extends OrbitStore>(T instance) {
    final old = _stores.remove(T);
    if (old != null) {
      old.dispose();
      _purgeUndoEntriesFor(old);
    }
    _stores[T] = instance;
    try {
      instance._runInit();
    } catch (_) {
      _stores.remove(T);
      instance.dispose();
      rethrow;
    }
  }

  /// Disposes and removes store [T] from the registry — e.g. on logout,
  /// so the next [use] call builds a fresh instance. Runs
  /// [OrbitStore.onDispose] on the way out.
  static void reset<T extends OrbitStore>() {
    final store = _stores.remove(T);
    if (store != null) {
      store.dispose();
      _purgeUndoEntriesFor(store);
    }
  }

  /// Disposes and clears every registered store. Mainly useful in test
  /// `tearDown` to stop state leaking between test cases.
  ///
  /// Note: does NOT clear [changeLog] — call [clearChangeLog] explicitly
  /// if you also want to reset the mutation history.
  static void resetAll() {
    _globalBatchDepth = 0;
    _globalPendingStores.clear();
    _globalWatchdogTimer?.cancel();
    _globalWatchdogTimer = null;
    _undoStack.clear();
    _redoStack.clear();
    _isRestoring = false;
    final stores = List<OrbitStore>.of(_stores.values);
    _stores.clear();
    for (final store in stores) {
      store.dispose();
    }
  }

  // ---- Shared app-lifecycle dispatch ---------------------------------
  //
  // Every OrbitStore wants to know when the app resumes (onResume()),
  // but registering one WidgetsBindingObserver *per store instance*
  // means every store creation/disposal does an add/remove on
  // WidgetsBinding's global observer list — and removal there is a
  // linear scan, so churn (e.g. repeatedly opening/closing OrbitScope'd
  // dialogs or list-item forms) turns into O(n^2) work over the app's
  // lifetime. A single shared observer that fans out to all live
  // stores avoids that, and as a bonus isolates one store's onResume()
  // throwing from blocking the others.
  // Set.identity(), not a plain <OrbitStore>{}: tracks object identity
  // of live stores, not a possibly-overridden ==/hashCode on a user's
  // OrbitStore subclass.
  static final Set<OrbitStore> _liveStores = Set<OrbitStore>.identity();
  static _OrbitLifecycleObserver? _lifecycleObserver;

  static void _attachLifecycle(OrbitStore store) {
    _liveStores.add(store);
    if (_lifecycleObserver != null) return;
    try {
      final observer = _OrbitLifecycleObserver();
      WidgetsBinding.instance.addObserver(observer);
      _lifecycleObserver = observer;
    } catch (_) {
      // No live WidgetsBinding (e.g. a plain `test()` unit test without
      // TestWidgetsFlutterBinding.ensureInitialized()) — onResume()
      // just won't fire; every other Orbit feature still works fine.
    }
  }

  static void _detachLifecycle(OrbitStore store) {
    _liveStores.remove(store);
    // When the last live store is gone, tear down the shared observer so it
    // doesn't leak and so the next _attachLifecycle() can register a fresh one.
    if (_liveStores.isEmpty && _lifecycleObserver != null) {
      try {
        WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
      } catch (_) {}
      _lifecycleObserver = null;
    }
  }
}

class _OrbitLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Snapshot first: a store's onResume() might itself create/dispose
    // other stores, which would otherwise mutate the set mid-iteration.
    for (final store in List<OrbitStore>.of(Orbit._liveStores)) {
      if (store._disposed) continue;
      try {
        store.onResume();
      } catch (exception, stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: exception,
          stack: stackTrace,
          library: 'orbit',
          context:
              ErrorDescription('inside onResume() for ${store.runtimeType}'),
        ));
      }
    }
  }
}
