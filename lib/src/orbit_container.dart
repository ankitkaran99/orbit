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
    _stores.remove(T)?.dispose();
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
    store?.dispose();
  }

  /// Disposes and clears every registered store. Mainly useful in test
  /// `tearDown` to stop state leaking between test cases.
  static void resetAll() {
    final stores = List<OrbitStore>.of(_stores.values);
    _stores.clear();
    _log.clear();
    for (final store in stores) {
      store.dispose();
    }
  }
}
