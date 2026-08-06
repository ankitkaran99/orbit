part of '../orbit.dart';

/// Represents the state of an asynchronous operation.
sealed class AsyncValue<T> {
  const AsyncValue();

  /// Creates an [AsyncData] with the provided [value].
  const factory AsyncValue.data(T value) = AsyncData<T>;

  /// Creates an [AsyncLoading] state.
  const factory AsyncValue.loading() = AsyncLoading<T>;

  /// Creates an [AsyncError] state with the provided [error] and optional [stackTrace].
  const factory AsyncValue.error(Object error, [StackTrace? stackTrace]) =
      AsyncError<T>;

  /// Maps the current state to a value or widget based on the subclass type.
  R when<R>({
    required R Function(T data) data,
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
  });

  /// The value of type [T] if this is [AsyncData], otherwise null.
  T? get valueOrNull;

  /// Whether this state is [AsyncLoading].
  bool get isLoading;

  /// Whether this state is [AsyncData].
  bool get hasValue;

  /// Whether this state is [AsyncError].
  bool get hasError;
}

/// The successful state of an asynchronous operation containing [value].
class AsyncData<T> extends AsyncValue<T> {
  const AsyncData(this.value);

  /// The resolved value.
  final T value;

  @override
  R when<R>({
    required R Function(T data) data,
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
  }) =>
      data(value);

  @override
  T? get valueOrNull => value;

  @override
  bool get isLoading => false;

  @override
  bool get hasValue => true;

  @override
  bool get hasError => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AsyncData<T> &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AsyncData($value)';
}

/// The loading state of an asynchronous operation.
class AsyncLoading<T> extends AsyncValue<T> {
  const AsyncLoading();

  @override
  R when<R>({
    required R Function(T data) data,
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
  }) =>
      loading();

  @override
  T? get valueOrNull => null;

  @override
  bool get isLoading => true;

  @override
  bool get hasValue => false;

  @override
  bool get hasError => false;

  @override
  bool operator ==(Object other) => other is AsyncLoading<T>;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'AsyncLoading()';
}

/// The failure state of an asynchronous operation containing [error] and optional [stackTrace].
class AsyncError<T> extends AsyncValue<T> {
  const AsyncError(this.error, [this.stackTrace]);

  /// The error object.
  final Object error;

  /// The optional stack trace.
  final StackTrace? stackTrace;

  @override
  R when<R>({
    required R Function(T data) data,
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
  }) =>
      error(this.error, stackTrace);

  @override
  T? get valueOrNull => null;

  @override
  bool get isLoading => false;

  @override
  bool get hasValue => false;

  @override
  bool get hasError => true;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AsyncError<T> &&
          runtimeType == other.runtimeType &&
          error == other.error &&
          stackTrace == other.stackTrace;

  @override
  int get hashCode => Object.hash(error, stackTrace);

  @override
  String toString() => 'AsyncError($error)';
}

/// An [OrbitStore] that exposes the state of a [Future].
class FutureProvider<T> extends OrbitStore {
  /// Creates a [FutureProvider] with the given [_build] function.
  FutureProvider(this._build);

  final Future<T> Function() _build;
  AsyncValue<T> _state = const AsyncLoading();
  int _requestCount = 0;

  /// The current state of the future operation.
  AsyncValue<T> get state => _state;

  @override
  FutureOr<void> init() {
    // Rethrow so a failing initial fetch surfaces through
    // `initError`/`ready` — unlike the public refresh() below, which
    // never rethrows since it's meant to be called directly by widgets.
    return _refresh(rethrowError: true);
  }

  /// Triggers the future builder again, transitioning state back to loading.
  ///
  /// Always completes successfully — a failure is reported through
  /// [state] as an [AsyncError], not by throwing, so it's safe to pass
  /// directly as e.g. `RefreshIndicator.onRefresh` without a try/catch.
  /// Check `state.hasError` (or use [AsyncValue.when]) if you need to
  /// react to a failed refresh.
  Future<void> refresh() => _refresh(rethrowError: false);

  Future<void> _refresh({required bool rethrowError}) async {
    if (_disposed) return;
    final requestId = ++_requestCount;
    mutate(() {
      _state = const AsyncLoading();
    }, label: 'loading');
    try {
      final res = await _build();
      if (_disposed || requestId != _requestCount) return;
      mutate(() {
        _state = AsyncValue.data(res);
      }, label: 'data');
    } catch (err, stack) {
      if (_disposed || requestId != _requestCount) return;
      mutate(() {
        _state = AsyncValue.error(err, stack);
      }, label: 'error');
      if (rethrowError) rethrow;
    }
  }

  @override
  Map<String, Object?>? snapshot() {
    return {
      'state': _state.toString(),
    };
  }
}

/// An [OrbitStore] that exposes the state of a [Stream].
class StreamProvider<T> extends OrbitStore {
  /// Creates a [StreamProvider] with the given [_build] function.
  StreamProvider(this._build);

  final Stream<T> Function() _build;
  AsyncValue<T> _state = const AsyncLoading();
  StreamSubscription<T>? _subscription;

  /// The current state of the stream subscription.
  AsyncValue<T> get state => _state;

  @override
  FutureOr<void> init() {
    _subscribe();
  }

  void _subscribe() {
    _subscription?.cancel();
    try {
      _subscription = _build().listen(
        (value) {
          if (_disposed) return;
          mutate(() {
            _state = AsyncValue.data(value);
          }, label: 'data');
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_disposed) return;
          mutate(() {
            _state = AsyncValue.error(error, stackTrace);
          }, label: 'error');
        },
      );
    } catch (err, stack) {
      if (_disposed) return;
      mutate(() {
        _state = AsyncValue.error(err, stack);
      }, label: 'error');
    }
  }

  /// Re-subscribes to the stream, resetting state to loading.
  void refresh() {
    if (_disposed) return;
    mutate(() {
      _state = const AsyncLoading();
    }, label: 'loading');
    _subscribe();
  }

  @override
  void onDispose() {
    _subscription?.cancel();
  }

  @override
  Map<String, Object?>? snapshot() {
    return {
      'state': _state.toString(),
    };
  }
}

/// An interface passed to the compute function in [ComputedStore] to read other stores.
abstract class StoreReader {
  /// Reads store [T] using [storeRef] and registers it as a dependency.
  T call<T extends OrbitStore>(OrbitStoreRef<T> storeRef);
}

/// Private implementation of [StoreReader] used to track dependencies.
class _ComputedStoreReader implements StoreReader {
  _ComputedStoreReader(this._onRead);

  final OrbitStore Function(OrbitStore store) _onRead;

  @override
  T call<T extends OrbitStore>(OrbitStoreRef<T> storeRef) {
    final instance = storeRef();
    _onRead(instance);
    return instance;
  }
}

/// An [OrbitStore] that computes derived state from other stores.
///
/// It automatically tracks which stores are read via the `watch` reader
/// passed to its compute function, and recomputes and notifies its own
/// listeners when any dependency changes.
///
/// By default, the recomputed value is compared with the previous one
/// using `==` to decide whether to notify listeners. That's fine for
/// primitives and value types, but if your compute function returns a
/// fresh `List`/`Map`/`Set` each time (as most `.where().toList()`-style
/// derivations do), `==` compares by identity and is *always* unequal —
/// so listeners get notified on every dependency change even when the
/// derived contents haven't actually changed. Pass [equals] for
/// value-based comparison in that case, e.g. using
/// `package:collection`'s `ListEquality`/`SetEquality`/`MapEquality`.
///
/// A `ComputedStore` that reads another `ComputedStore` which
/// (directly or transitively) reads back into the first one throws a
/// clear `StateError` describing the cycle, rather than crashing with
/// a confusing `LateInitializationError`.
class ComputedStore<T> extends OrbitStore {
  /// Creates a [ComputedStore] with the given [_compute] function.
  ///
  /// [equals] overrides how the new value is compared with the
  /// previous one; defaults to `==`.
  ComputedStore(this._compute, {bool Function(T previous, T next)? equals})
      : _equals = equals ?? ((a, b) => a == b);

  final T Function(StoreReader watch) _compute;
  final bool Function(T previous, T next) _equals;
  late T _state;

  /// The computed value.
  ///
  /// Normally recomputation happens reactively: `OrbitStore.dispose()`
  /// notifies dependents immediately when a dependency is torn down
  /// (e.g. via `Orbit.reset<T>()`), which triggers [_recompute] right
  /// away. This getter's own disposed-dependency check is just a
  /// fallback for anything that disposed a dependency without going
  /// through the normal notify path.
  T get state {
    // Reading .state on a store that's still mid-computation (i.e.
    // it's on the compute stack below us) means a cycle: Orbit.use()
    // already registered this instance before its first _runCompute()
    // finished, so whoever's reading it back mid-flight would
    // otherwise hit a bare "LateInitializationError" on _state instead
    // of a clear explanation. See _computeStack.
    _assertNotComputing();
    if (_hasDisposedDependencies()) {
      _recompute();
    }
    return _state;
  }

  bool _hasDisposedDependencies() {
    for (final dep in _dependencies.keys) {
      if (dep._disposed) {
        return true;
      }
    }
    return false;
  }

  // Map.identity() (not a plain {}) deliberately: this tracks *object
  // identity* of dependency stores, not their notion of equality — a
  // user's OrbitStore subclass may legitimately override ==/hashCode
  // for its own domain reasons, and that must not affect Orbit's own
  // internal bookkeeping about which specific instances are wired up.
  final Map<OrbitStore, void Function()> _dependencies = Map.identity();

  // Tracks which ComputedStores are currently mid-computation, across
  // *all* ComputedStore<T> instances (a static field is per-class, not
  // per type argument, so this one stack is shared regardless of T).
  // Lets a circular dependency between two ComputedStores surface as a
  // clear error pointing at the cycle, instead of a bare
  // "LateInitializationError: Field '_state' has not been initialized"
  // several frames deep — which is what you'd get otherwise, since
  // Orbit.use() registers a store before running its init/compute, so
  // reading back into a store that's still mid-computation returns the
  // half-built instance rather than looping forever.
  static final List<ComputedStore> _computeStack = [];

  void _assertNotComputing() {
    if (!_computeStack.any((s) => identical(s, this))) return;
    final cycle = [
      ..._computeStack.map((s) => s.runtimeType),
      runtimeType,
    ].join(' -> ');
    throw StateError(
      'Circular ComputedStore dependency detected: $cycle.\n'
      "One of these stores' compute function reads (directly or "
      'transitively) its own output through another ComputedStore. '
      'Break the cycle by having one of them depend on a plain '
      'OrbitStore value instead.',
    );
  }

  @override
  FutureOr<void> init() {
    _state = _runCompute();
  }

  T _runCompute() {
    _assertNotComputing();
    _computeStack.add(this);
    try {
      // Set.identity(), not a plain <OrbitStore>{}: dependency tracking must
      // be identity-based to match the Map.identity() used in _dependencies —
      // a user's OrbitStore subclass may override ==/hashCode for its own
      // domain reasons, which must never affect Orbit's internal wiring.
      final activeDeps = Set<OrbitStore>.identity();
      final reader = _ComputedStoreReader((store) {
        activeDeps.add(store);
        return store;
      });

      final newValue = _compute(reader);

      // Remove dependencies no longer active
      _dependencies.removeWhere((dep, unsubscribe) {
        if (!activeDeps.contains(dep)) {
          unsubscribe();
          return true;
        }
        return false;
      });

      // Add newly registered dependencies
      for (final dep in activeDeps) {
        if (!_dependencies.containsKey(dep)) {
          final listener = _recompute;
          dep.addListener(listener);
          _dependencies[dep] = () => dep.removeListener(listener);
        }
      }

      return newValue;
    } finally {
      _computeStack.removeLast();
    }
  }

  void _recompute() {
    late T newValue;
    try {
      newValue = _runCompute();
    } catch (exception, stackTrace) {
      // A buggy compute function must not crash the dependency store's
      // mutate() call — _recompute runs as a ChangeNotifier listener, so
      // an uncaught exception here propagates out of notifyListeners() on
      // the upstream store. Report the error and leave state at the last
      // known-good value instead.
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stackTrace,
        library: 'orbit',
        context:
            ErrorDescription('inside the compute function for $runtimeType — '
                'state left at last known-good value'),
      ));
      return;
    }
    bool changed;
    try {
      changed = !_equals(_state, newValue);
    } catch (exception, stackTrace) {
      // A buggy equals comparator must not permanently freeze this
      // store's state at a stale value just because it can't safely
      // tell old and new apart — fail open (treat it as changed) so
      // reactivity keeps working, and report the bug separately.
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stackTrace,
        library: 'orbit',
        context: ErrorDescription(
            'inside the equals comparator for $runtimeType — treating '
            'the value as changed so state does not get stuck'),
      ));
      changed = true;
    }
    if (changed) {
      mutate(() {
        _state = newValue;
      }, label: 'recompute');
    }
  }

  @override
  void onDispose() {
    for (final unsubscribe in _dependencies.values) {
      unsubscribe();
    }
    _dependencies.clear();
  }

  @override
  Map<String, Object?>? snapshot() {
    return {
      'state': _state,
    };
  }
}
