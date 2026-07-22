part of '../orbit.dart';

/// Base class for all Orbit stores.
///
/// Declare state as **private** fields with public getters — not public
/// mutable fields. Only code inside the store's own file can then touch
/// them, so every change is forced through [mutate], which is what
/// keeps rebuilds, [Orbit.observe] middleware, and [Orbit.changeLog]
/// honest. A public mutable field can still be written directly from
/// outside the class, silently skipping all of that.
///
/// ```dart
/// class CounterStore extends OrbitStore {
///   int _count = 0;
///   int get count => _count;
///
///   // Getters are just Dart getters — no special "computed" API
///   // needed, they always read the latest fields.
///   int get doubleCount => _count * 2;
///
///   void increment() => mutate(() => _count++);
///
///   // Optional: called once, sync or async, right after creation.
///   @override
///   Future<void> init() async {
///     _count = await loadPersistedCount();
///   }
///
///   // Optional: cleanup when the store is disposed.
///   @override
///   void onDispose() => _subscription?.cancel();
///
///   // Optional: powers Orbit.observe/changeLog diffing.
///   @override
///   Map<String, Object?> debugSnapshot() => {'count': _count};
/// }
/// ```
abstract class OrbitStore extends ChangeNotifier {
  bool _disposed = false;
  bool _initStarted = false;
  int _listenerCount = 0;
  _OrbitLifecycleObserver? _lifecycleObserver;
  final List<void Function()> _watchDisposers = [];
  final Map<String, Timer> _activeTimers = {};

  final Completer<void> _readyCompleter = Completer<void>()
    ..future.catchError((_) {});
  // ^ that catchError just prevents Dart's "unhandled exception" console
  // noise if nobody ever awaits `ready` on a store whose init() fails;
  // it doesn't stop `ready` itself from surfacing the real error to
  // whoever *does* await it.

  /// Set if [init] threw synchronously, or its returned future
  /// completed with an error. `null` otherwise.
  Object? initError;

  /// The stack trace paired with [initError], if any.
  StackTrace? initStackTrace;

  /// Completes once [init] finishes.
  ///
  /// Already complete by the time `Orbit.use` returns the store if
  /// [init] is synchronous (or not overridden). If [init] is
  /// asynchronous, await this when you need to know setup has actually
  /// finished — e.g. to gate a loading screen. Completes with an error
  /// if [init] failed.
  Future<void> get ready => _readyCompleter.future;

  /// True once [ready] has completed successfully. `false` if it hasn't
  /// completed yet, or if it completed with an error — check
  /// [initError] to tell those two apart.
  bool get isReady => _readyCompleter.isCompleted && initError == null;

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    _listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_disposed) return;
    if (_listenerCount > 0) _listenerCount--;
    super.removeListener(listener);
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  static final RegExp _stackFrameRegExp = RegExp(r'#\d+\s+([^\s\(]+)');
  static final RegExp _jsStackFrameRegExp = RegExp(r'at\s+([^\s\(]+)');
  static final RegExp _firefoxStackFrameRegExp = RegExp(r'^([^@\s]+)@');
  static final RegExp _anonymousClosureRegExp =
      RegExp(r'\.<anonymous closure>.*');
  static final RegExp _asyncRegExp = RegExp(r'\.<async>.*');

  String? _inferLabel(String? explicitLabel, [StackTrace? testTrace]) {
    if (explicitLabel != null) return explicitLabel;
    try {
      var trace = (testTrace ?? StackTrace.current).toString();
      var newlineCount = 0;
      var index = 0;
      while (newlineCount < 10 && index < trace.length) {
        index = trace.indexOf('\n', index);
        if (index == -1) break;
        newlineCount++;
        index++;
      }
      if (index != -1 && index < trace.length) {
        trace = trace.substring(0, index);
      }
      final frames = trace.split('\n');
      for (final line in frames) {
        var match = _stackFrameRegExp.firstMatch(line);
        match ??= _jsStackFrameRegExp.firstMatch(line);
        match ??= _firefoxStackFrameRegExp.firstMatch(line);
        if (match == null) continue;
        var symbol = match.group(1)!;
        if (symbol.startsWith('OrbitStore.') || symbol == 'OrbitStore') {
          continue;
        }
        symbol = symbol
            .replaceAll(_anonymousClosureRegExp, '')
            .replaceAll(_asyncRegExp, '');
        final parts = symbol.split('.');
        final methodName = parts.last;
        if (methodName.isNotEmpty &&
            methodName != 'mutate' &&
            methodName != 'mutateAsync') {
          return methodName;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Exposed helper for testing label inference on custom stack traces.
  @visibleForTesting
  String? inferLabelForTest(String? explicitLabel, StackTrace trace) {
    return _inferLabel(explicitLabel, trace);
  }

  /// Runs [action], then notifies every listener that state changed.
  ///
  /// Returns the result of [action].
  /// Optionally pass [label] to override the action name for [Orbit.observe] middleware
  /// and debug logging — e.g. `mutate(() => count++)` (automatically uses `'increment'`).
  /// If omitted, [label] is automatically inferred from the calling method name.
  /// If you also override [debugSnapshot], Orbit logs exactly which
  /// fields changed.
  @protected
  R mutate<R>(R Function() action, {String? label}) {
    final tracking = Orbit.debugLogging || Orbit._hasObservers;
    final inferredLabel = tracking ? _inferLabel(label) : label;
    final before = tracking ? debugSnapshot() : null;
    try {
      final result = action();
      if (!_disposed) notifyListeners();
      if (tracking) {
        Orbit._notify(
          this,
          OrbitMutation(
            store: this,
            action: inferredLabel,
            timestamp: DateTime.now(),
            listenerCount: _listenerCount,
            before: before,
            after: debugSnapshot(),
          ),
        );
      }
      return result;
    } catch (_) {
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  /// Awaits [action], then notifies listeners once it settles.
  ///
  /// Returns the result of [action].
  /// Pass [label] to name the action for [Orbit.observe] middleware and
  /// debug logging. If omitted, [label] is automatically inferred from the calling method name.
  /// If you want the UI to update *during* the async work too (e.g. to
  /// flip a `loading` flag before the await), call [mutate] yourself
  /// before and after instead of using this helper.
  @protected
  Future<R> mutateAsync<R>(
    Future<R> Function() action, {
    String? label,
  }) async {
    final tracking = Orbit.debugLogging || Orbit._hasObservers;
    final inferredLabel = tracking ? _inferLabel(label) : label;
    final before = tracking ? debugSnapshot() : null;
    try {
      final result = await action();
      if (!_disposed) notifyListeners();
      if (tracking) {
        Orbit._notify(
          this,
          OrbitMutation(
            store: this,
            action: inferredLabel,
            timestamp: DateTime.now(),
            listenerCount: _listenerCount,
            before: before,
            after: debugSnapshot(),
          ),
        );
      }
      return result;
    } catch (_) {
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  /// Override to return a snapshot of your state's fields, used by
  /// [Orbit.observe]/[Orbit.changeLog] to report exactly what changed
  /// on each mutation. Only computed when something's actually
  /// listening ([Orbit.debugLogging] is on, or at least one observer is
  /// registered) — never in a plain release build — so it's fine for
  /// this to be a little more expensive than your hot-path code.
  Map<String, Object?>? debugSnapshot() => null;

  /// Called exactly once, immediately after the store is first created
  /// by `Orbit.use` (or `OrbitScope`). Override to run setup logic —
  /// e.g. loading persisted state from disk, or an initial network
  /// fetch. Can be synchronous or asynchronous.
  ///
  /// A synchronous [init] (or the default no-op) has already finished
  /// by the time the store is returned to its caller — [ready] is
  /// immediately complete. An asynchronous [init] keeps running in the
  /// background; the store is still usable right away (its fields just
  /// haven't been touched by [init] yet), and [ready] completes once it
  /// finishes.
  ///
  /// If [init] throws synchronously, the store is disposed and never
  /// registered — the caller's `Orbit.use`/`OrbitScope` rethrows
  /// immediately. If the *returned future* fails instead, the store
  /// stays registered (it was already handed out) but [initError] is
  /// set and [ready] completes with that error.
  FutureOr<void> init() {}

  /// Called when this store is disposed — via `Orbit.reset<T>()`,
  /// `Orbit.resetAll()`, `Orbit.override<T>()`, or when an
  /// `OrbitScope<T>` unmounts. Override to clean up timers, stream
  /// subscriptions, and the like. Runs before the underlying
  /// `ChangeNotifier` is disposed.
  void onDispose() {}

  /// Called when the app returns to the foreground
  /// (`AppLifecycleState.resumed`) while this store is alive — handy
  /// for refreshing time-sensitive data. No-op by default.
  ///
  /// Requires a live `WidgetsBinding` (true in any real app, or a
  /// `testWidgets` test). In a plain `test()` unit test without one,
  /// this simply never fires — every other Orbit feature still works.
  void onResume() {}

  void _runInit() {
    if (_initStarted) return;
    _initStarted = true;
    _attachLifecycle();
    FutureOr<void> result;
    try {
      result = init();
    } catch (error, stackTrace) {
      initError = error;
      initStackTrace = stackTrace;
      _readyCompleter.completeError(error, stackTrace);
      rethrow;
    }
    if (result is Future<void>) {
      result.then(
        (_) => _readyCompleter.complete(),
        onError: (Object error, StackTrace stackTrace) {
          initError = error;
          initStackTrace = stackTrace;
          _readyCompleter.completeError(error, stackTrace);
        },
      );
    } else {
      _readyCompleter.complete();
    }
  }

  void _attachLifecycle() {
    try {
      final observer = _OrbitLifecycleObserver(this);
      WidgetsBinding.instance.addObserver(observer);
      _lifecycleObserver = observer;
    } catch (_) {
      // No live WidgetsBinding (e.g. a plain `test()` unit test without
      // TestWidgetsFlutterBinding.ensureInitialized()) — onResume()
      // just won't fire; every other Orbit feature still works fine.
    }
  }

  void _detachLifecycle() {
    final observer = _lifecycleObserver;
    if (observer == null) return;
    try {
      WidgetsBinding.instance.removeObserver(observer);
    } catch (_) {}
    _lifecycleObserver = null;
  }

  /// Watches another global store and executes [onChange] whenever it notifies.
  /// Automatically unsubscribes when this store is disposed.
  void watch<S extends OrbitStore>(
    OrbitStoreRef<S> storeRef,
    void Function(S store) onChange,
  ) {
    final other = storeRef();
    final listener = () => onChange(other);
    other.addListener(listener);
    _watchDisposers.add(() => other.removeListener(listener));
  }

  /// Debounces [action], executing it only after [duration] of inactivity.
  ///
  /// Subsequent calls with the same [id] cancel the pending timer and schedule a new one.
  /// Automatically cancels active timers when the store is disposed.
  void debounce(
    String id,
    Duration duration,
    FutureOr<void> Function() action,
  ) {
    if (_disposed) return;
    _activeTimers[id]?.cancel();
    _activeTimers[id] = Timer(duration, () async {
      _activeTimers.remove(id);
      if (_disposed) return;
      try {
        await action();
      } catch (exception, stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: exception,
          stack: stackTrace,
          library: 'orbit',
          context:
              ErrorDescription('inside debounced action "$id" in $runtimeType'),
        ));
      }
    });
  }

  /// Throttles [action], executing it immediately and rate-limiting subsequent calls to at most once per [duration].
  ///
  /// Subsequent calls with the same [id] within the duration are ignored.
  /// Automatically cancels active timers when the store is disposed.
  void throttle(
    String id,
    Duration duration,
    FutureOr<void> Function() action,
  ) {
    if (_disposed) return;
    if (_activeTimers.containsKey(id)) return;

    // leading-edge: execute immediately
    try {
      final FutureOr<void> result = action();
      if (result is Future<void>) {
        result.catchError((Object exception, StackTrace stackTrace) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: exception,
            stack: stackTrace,
            library: 'orbit',
            context: ErrorDescription(
                'inside throttled async action "$id" in $runtimeType'),
          ));
        });
      }
    } catch (exception, stackTrace) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stackTrace,
        library: 'orbit',
        context:
            ErrorDescription('inside throttled action "$id" in $runtimeType'),
      ));
    }

    _activeTimers[id] = Timer(duration, () {
      _activeTimers.remove(id);
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detachLifecycle();
    onDispose();
    for (final timer in _activeTimers.values) {
      timer.cancel();
    }
    _activeTimers.clear();
    for (final dispose in _watchDisposers) {
      try {
        dispose();
      } catch (_) {}
    }
    _watchDisposers.clear();
    super.dispose();
  }
}

class _OrbitLifecycleObserver with WidgetsBindingObserver {
  _OrbitLifecycleObserver(this._store);
  final OrbitStore _store;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store.onResume();
    }
  }
}
