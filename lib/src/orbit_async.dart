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
    return refresh();
  }

  /// Triggers the future builder again, transitioning state back to loading.
  Future<void> refresh() async {
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
      rethrow;
    }
  }

  @override
  Map<String, Object?>? debugSnapshot() {
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
    super.onDispose();
  }

  @override
  Map<String, Object?>? debugSnapshot() {
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
class ComputedStore<T> extends OrbitStore {
  /// Creates a [ComputedStore] with the given [_compute] function.
  ComputedStore(this._compute);

  final T Function(StoreReader watch) _compute;
  late T _state;

  /// The computed value.
  T get state {
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

  final Map<OrbitStore, void Function()> _dependencies = {};

  @override
  FutureOr<void> init() {
    _state = _runCompute();
  }

  T _runCompute() {
    final activeDeps = <OrbitStore>{};
    final reader = _ComputedStoreReader((store) {
      activeDeps.add(store);
      return store;
    });

    try {
      final newValue = _compute(reader);

      final oldDeps = _dependencies.keys.toSet();
      final toRemove = oldDeps.difference(activeDeps);
      final toAdd = activeDeps.difference(oldDeps);

      for (final dep in toRemove) {
        final unsubscribe = _dependencies.remove(dep);
        unsubscribe?.call();
      }

      for (final dep in toAdd) {
        final listener = _recompute;
        dep.addListener(listener);
        _dependencies[dep] = () => dep.removeListener(listener);
      }

      return newValue;
    } catch (_) {
      rethrow;
    }
  }

  void _recompute() {
    final newValue = _runCompute();
    if (_state != newValue) {
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
    super.onDispose();
  }

  @override
  Map<String, Object?>? debugSnapshot() {
    return {
      'state': _state,
    };
  }
}
