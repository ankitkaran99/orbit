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
///   // Optional: powers Orbit.observe/changeLog diffing, and undo/redo
///   // if this store also mixes in Undoable.
///   @override
///   Map<String, Object?> snapshot() => {'count': _count};
/// }
/// ```
abstract class OrbitStore extends ChangeNotifier {
  bool _disposed = false;
  bool _initStarted = false;
  int _listenerCount = 0;
  final List<void Function()> _watchDisposers = [];
  // Kept separate (rather than one shared map) so a debounce() and a
  // throttle() call using the same id don't collide with each other.
  final Map<String, Timer> _debounceTimers = {};
  final Map<String, Timer> _throttleTimers = {};

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
    // Decrement only when positive: ChangeNotifier.removeListener() is a
    // no-op if the callback was never registered (e.g. it was added before
    // this store was disposed but removeListener was called after). Guarding
    // here prevents _listenerCount from going negative in those cases.
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
      final trace = (testTrace ?? StackTrace.current).toString();
      var newlineCount = 0;
      var index = 0;
      while (newlineCount < 10 && index < trace.length) {
        final nextIndex = trace.indexOf('\n', index);
        if (nextIndex == -1) break;
        newlineCount++;
        index = nextIndex + 1;
      }
      final trimmedTrace =
          index < trace.length ? trace.substring(0, index) : trace;
      final frames = trimmedTrace.split('\n');
      for (final line in frames) {
        var match = _stackFrameRegExp.firstMatch(line);
        match ??= _jsStackFrameRegExp.firstMatch(line);
        match ??= _firefoxStackFrameRegExp.firstMatch(line);
        if (match == null) continue;
        var symbol = match.group(1)!;
        // Skip all internal Orbit base-class frames so they don't leak through
        // as the inferred label for user subclasses (e.g. a store extending
        // FutureProvider would otherwise see '_refresh' as the action name).
        if (symbol.startsWith('OrbitStore.') ||
            symbol.startsWith('FutureProvider.') ||
            symbol.startsWith('StreamProvider.') ||
            symbol.startsWith('ComputedStore.') ||
            symbol == 'OrbitStore') {
          continue;
        }
        symbol = symbol
            .replaceAll(_anonymousClosureRegExp, '')
            .replaceAll(_asyncRegExp, '');
        final parts = symbol.split('.');
        final methodName = parts.last;
        if (methodName.isNotEmpty &&
            methodName != 'mutate' &&
            methodName != 'mutateAsync' &&
            methodName != 'batch' &&
            methodName != '_onMutationError' &&
            methodName != '_dispatchNotify' &&
            methodName != '_refresh' &&
            methodName != '_subscribe' &&
            methodName != '_recompute') {
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

  /// Calls [snapshot], catching and reporting any exception instead
  /// of letting it propagate. A bug in someone's override (a stale field reference, an
  /// unfinished refactor, whatever) must never be able to block the
  /// actual mutation from running, or replace/mask a real error from
  /// an action with an unrelated crash.
  Map<String, Object?>? _safeSnapshot() {
    try {
      return snapshot();
    } catch (exception, stackTrace) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stackTrace,
        library: 'orbit',
        context: ErrorDescription(
            'inside snapshot() on $runtimeType — ignoring snapshot for logging'),
      ));
      return null;
    }
  }

  int _scopedBatchDepth = 0;
  bool _scopedPendingNotify = false;
  Timer? _scopedWatchdogTimer;

  /// Runs [fn] inside a store-scoped batch.
  ///
  /// Only notifications for this store are deferred while the batch is open.
  /// Other stores mutated inside notify immediately as normal (unless a global
  /// `Orbit.batch` is also active).
  FutureOr<T> batch<T>(
    FutureOr<T> Function() fn, {
    String? label,
  }) {
    final effectiveLabel = label ?? '${runtimeType}.batch';
    _openScopedBatch(effectiveLabel);
    Orbit._openUndoBatch(effectiveLabel);

    try {
      final result = fn();
      if (result is Future) {
        return (result as Future).whenComplete(() {
          Orbit._closeUndoBatch();
          _closeScopedBatch();
        }) as FutureOr<T>;
      }
      Orbit._closeUndoBatch();
      _closeScopedBatch();
      return result;
    } catch (error) {
      Orbit._closeUndoBatch();
      _closeScopedBatch();
      rethrow;
    }
  }

  void _openScopedBatch(String label) {
    _scopedBatchDepth++;
    if (_scopedBatchDepth == 1) {
      if (kDebugMode) {
        final trace = StackTrace.current;
        _scopedWatchdogTimer = Timer(OrbitBatchWatchdog.warnAfter, () {
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

  void _closeScopedBatch() {
    if (_scopedBatchDepth <= 0) return;
    _scopedBatchDepth--;
    if (_scopedBatchDepth == 0) {
      _scopedWatchdogTimer?.cancel();
      _scopedWatchdogTimer = null;

      if (Orbit._globalBatchDepth > 0) return;

      if (_scopedPendingNotify) {
        _scopedPendingNotify = false;
        if (!_disposed) {
          _dispatchNotify();
        }
      }
    }
  }

  void _dispatchNotify() {
    if (_disposed) return;
    if (Orbit._globalBatchDepth > 0) {
      Orbit._globalPendingStores.add(this);
      _scopedPendingNotify = true;
    } else if (_scopedBatchDepth > 0) {
      _scopedPendingNotify = true;
    } else {
      _scopedPendingNotify = false;
      notifyListeners();
    }
  }

  /// Runs [action], then notifies every listener that state changed.
  ///
  /// Supports both synchronous actions and asynchronous actions (returning a [Future]).
  /// For asynchronous actions, listeners are notified once the returned [Future] completes.
  ///
  /// Returns the result of [action].
  /// Optionally pass [label] to override the action name for [Orbit.observe] middleware
  /// and debug logging — e.g. `mutate(() => count++)` (automatically uses `'increment'`).
  /// If omitted, [label] is automatically inferred from the calling method name.
  /// If you also override [snapshot], Orbit logs exactly which
  /// fields changed.
  @protected
  R mutate<R>(R Function() action, {String? label}) {
    final tracking = Orbit.debugLogging || Orbit._hasObservers;
    // In non-release builds _notify must always run so that postEvent fires
    // and the VS Code / DevTools extension receives live state updates —
    // even when debugLogging is off and no observers are registered.
    final notify = tracking || !kReleaseMode;
    // Snapshots/label inference are gated on `notify`, not the narrower
    // `tracking`: postEvent (which powers the VS Code/DevTools extension)
    // fires whenever `notify` is true and reads `mutation.after` directly,
    // so it must always have a real snapshot to read — gating on `tracking`
    // alone left it silently empty whenever debugLogging was off and no
    // observers were registered, even with the extension attached.
    final inferredLabel = notify ? _inferLabel(label) : label;
    final before = notify ? _safeSnapshot() : null;

    try {
      final result = action();
      if (result is Future) {
        var hasError = false;
        Object? asyncError;
        StackTrace? asyncStack;

        return (result as Future)
            .catchError((Object error, StackTrace stackTrace) {
          hasError = true;
          asyncError = error;
          asyncStack = stackTrace;
          throw error;
        }).whenComplete(() {
          _dispatchNotify();
          if (notify) {
            Orbit._notify(
              this,
              OrbitMutation(
                store: this,
                action: inferredLabel,
                timestamp: DateTime.now(),
                listenerCount: _listenerCount,
                before: before,
                after: _safeSnapshot(),
                error: hasError ? asyncError : null,
                errorStackTrace: hasError ? asyncStack : null,
              ),
            );
          }
        }) as R;
      }

      _dispatchNotify();
      if (notify) {
        Orbit._notify(
          this,
          OrbitMutation(
            store: this,
            action: inferredLabel,
            timestamp: DateTime.now(),
            listenerCount: _listenerCount,
            before: before,
            after: _safeSnapshot(),
          ),
        );
      }
      return result;
    } catch (error, stackTrace) {
      _dispatchNotify();
      if (notify) {
        Orbit._notify(
          this,
          OrbitMutation(
            store: this,
            action: inferredLabel,
            timestamp: DateTime.now(),
            listenerCount: _listenerCount,
            before: before,
            after: _safeSnapshot(),
            error: error,
            errorStackTrace: stackTrace,
          ),
        );
      }
      rethrow;
    }
  }

  /// Asynchronously executes [action], then passes the result to [apply] inside [mutate] if successful.
  ///
  /// If an error occurs during [action], calls [onError] if provided; otherwise
  /// records the error and rethrows.
  @protected
  Future<void> mutateAsync<T>({
    required Future<T> Function() action,
    required void Function(T result) apply,
    void Function(Object error, StackTrace stack)? onError,
    String? label,
  }) async {
    if (_disposed) return;
    T result;
    try {
      result = await action();
    } catch (e, st) {
      if (onError != null) {
        onError(e, st);
      } else {
        _onMutationError(e, st, label);
        rethrow;
      }
      return;
    }

    if (_disposed) return;
    try {
      mutate(() => apply(result), label: label);
    } catch (e, st) {
      if (onError != null) {
        onError(e, st);
      } else {
        rethrow;
      }
    }
  }

  void _onMutationError(Object error, StackTrace stackTrace, String? label) {
    final tracking = Orbit.debugLogging || Orbit._hasObservers;
    final notify = tracking || !kReleaseMode;
    final inferredLabel = notify ? _inferLabel(label) : label;
    final before = notify ? _safeSnapshot() : null;
    if (notify) {
      Orbit._notify(
        this,
        OrbitMutation(
          store: this,
          action: inferredLabel,
          timestamp: DateTime.now(),
          listenerCount: _listenerCount,
          before: before,
          after: _safeSnapshot(),
          error: error,
          errorStackTrace: stackTrace,
        ),
      );
    }
  }

  /// Override to return a snapshot of your state's fields.
  ///
  /// Used by:
  /// 1. [Orbit.observe]/[Orbit.changeLog] to report exactly what changed on each mutation.
  /// 2. Stores mixing in [Undoable] to record state history for [Orbit.undo] / [Orbit.redo].
  Map<String, Object?>? snapshot() => null;

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
    Orbit._attachLifecycle(this);
  }

  void _detachLifecycle() {
    Orbit._detachLifecycle(this);
  }

  /// Watches another global store and executes [onChange] whenever it notifies.
  /// Automatically unsubscribes when this store is disposed.
  ///
  /// [onChange] may be synchronous or async. Errors from both sync throws
  /// and unhandled async rejections are routed to [FlutterError.reportError]
  /// rather than crashing the notifying store or silently dropping them.
  void watch<S extends OrbitStore>(
    OrbitStoreRef<S> storeRef,
    void Function(S store) onChange,
  ) {
    if (_disposed) return;
    final other = storeRef();
    if (other._disposed) return; // Don't attach to an already-disposed store
    final listener = () {
      if (_disposed) return;
      try {
        // Invoke via dynamic so we can inspect the runtime return value:
        // the public API is void Function(S) for type safety, but a user
        // may pass an async closure (Future<void> is assignable to void).
        // Capturing the dynamic result lets us attach a catchError to any
        // returned Future without triggering a use_of_void_result error.
        // ignore: avoid_dynamic_calls
        final dynamic result = (onChange as dynamic)(other);
        if (result is Future<void>) {
          result.catchError((Object exception, StackTrace stackTrace) {
            FlutterError.reportError(FlutterErrorDetails(
              exception: exception,
              stack: stackTrace,
              library: 'orbit',
              context: ErrorDescription(
                  'inside async watch callback on $runtimeType '
                  'watching ${other.runtimeType}'),
            ));
          });
        }
      } catch (exception, stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: exception,
          stack: stackTrace,
          library: 'orbit',
          context: ErrorDescription('inside watch callback on $runtimeType '
              'watching ${other.runtimeType}'),
        ));
      }
    };
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
    _debounceTimers[id]?.cancel();
    _debounceTimers[id] = Timer(duration, () async {
      _debounceTimers.remove(id);
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
    if (_throttleTimers.containsKey(id)) return;

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

    _throttleTimers[id] = Timer(duration, () {
      _throttleTimers.remove(id);
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scopedWatchdogTimer?.cancel();
    _scopedWatchdogTimer = null;
    _scopedBatchDepth = 0;
    _scopedPendingNotify = false;
    // One last notification, before teardown, so anything tracking this
    // store as a dependency (e.g. ComputedStore) finds out about the
    // disposal right away instead of only on its next unrelated read.
    // notifyListeners() itself now short-circuits on _disposed, so this
    // goes straight to the underlying ChangeNotifier.
    super.notifyListeners();
    _detachLifecycle();
    onDispose();
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    for (final timer in _throttleTimers.values) {
      timer.cancel();
    }
    _throttleTimers.clear();
    for (final dispose in _watchDisposers) {
      try {
        dispose();
      } catch (_) {}
    }
    _watchDisposers.clear();
    super.dispose();
  }
}
