part of '../orbit.dart';

/// Creates a store instance scoped to this widget's subtree, instead of
/// the app-wide singleton `Orbit.use<T>()` returns. Useful for dialogs,
/// tabs, nested navigators, or any reusable component that needs its
/// own independent copy of a store's state.
///
/// ```dart
/// OrbitScope<FormStore>(
///   create: () => FormStore(),
///   child: const FormDialog(),
/// )
/// ```
///
/// Inside the subtree, `OrbitBuilder<FormStore>` and
/// `OrbitSelector<FormStore, ...>` automatically pick up this scoped
/// instance instead of the global singleton — no change needed at the
/// call site. You can also reach it directly with
/// `OrbitScope.of<FormStore>(context)`.
///
/// Don't pass a `defineStore` reference (e.g. `counterStore`) as
/// [create] — calling it returns/creates the *global* singleton via
/// `Orbit.use`, defeating the point of scoping. Pass a bare constructor
/// instead: `create: () => CounterStore()`.
///
/// The store is created once, in [State.initState], and disposed when
/// this widget leaves the tree — it's never added to the global
/// registry, so `Orbit.read`/`reset`/`override` don't see it, and
/// multiple scopes of the same store type can coexist independently
/// (e.g. two open dialogs, each with their own `FormStore`).
class OrbitScope<T extends OrbitStore> extends StatefulWidget {
  const OrbitScope({super.key, required this.create, required this.child});

  /// Factory run once, in [State.initState], to create this scope's
  /// store instance.
  final T Function() create;

  final Widget child;

  /// Returns the nearest ancestor `OrbitScope<T>`'s store, or `null` if
  /// no such ancestor exists.
  static T? maybeOf<T extends OrbitStore>(
    BuildContext context, {
    bool listen = true,
  }) {
    if (listen) {
      return context
          .dependOnInheritedWidgetOfExactType<_OrbitScopeInherited<T>>()
          ?.store;
    }
    final element = context
        .getElementForInheritedWidgetOfExactType<_OrbitScopeInherited<T>>();
    return (element?.widget as _OrbitScopeInherited<T>?)?.store;
  }

  /// Returns the nearest ancestor `OrbitScope<T>`'s store.
  ///
  /// Throws a [FlutterError] if there's no `OrbitScope<T>` above
  /// [context] — wrap the relevant widget in one, or use
  /// `Orbit.use<T>()` for the app-wide singleton instead.
  ///
  /// Pass `listen: false` to read the store without subscribing this
  /// widget to rebuild on every change — e.g. inside a callback like
  /// `onPressed`, rather than directly in `build`.
  static T of<T extends OrbitStore>(
    BuildContext context, {
    bool listen = true,
  }) {
    final store = maybeOf<T>(context, listen: listen);
    if (store == null) {
      throw FlutterError(
        'OrbitScope.of<$T>() was called with a context that has no '
        'OrbitScope<$T> above it.\n'
        'Wrap the relevant widget in OrbitScope<$T>(create: () => ..., '
        'child: ...), or use Orbit.use<$T>() for the app-wide singleton.',
      );
    }
    return store;
  }

  @override
  State<OrbitScope<T>> createState() => _OrbitScopeState<T>();
}

class _OrbitScopeState<T extends OrbitStore> extends State<OrbitScope<T>> {
  late final T _store;

  @override
  void initState() {
    super.initState();
    _store = widget.create();
    try {
      _store._runInit();
    } catch (_) {
      _store.dispose();
      rethrow;
    }
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _OrbitScopeInherited<T>(store: _store, child: widget.child);
  }
}

class _OrbitScopeInherited<T extends OrbitStore> extends InheritedNotifier<T> {
  _OrbitScopeInherited({required this.store, required Widget child})
      : super(notifier: store, child: child);

  final T store;
}

/// Resolves store [T] for [context]: the nearest ancestor
/// `OrbitScope<T>` if there is one, otherwise the app-wide singleton
/// (creating it via [create] if this is the first request anywhere).
/// Used internally by `OrbitBuilder` and `OrbitSelector` so both
/// automatically respect scoping without any change at the call site.
T _resolveStore<T extends OrbitStore>(
  BuildContext context,
  T Function() create,
) {
  final element = context
      .getElementForInheritedWidgetOfExactType<_OrbitScopeInherited<T>>();
  if (element != null) {
    return (element.widget as _OrbitScopeInherited<T>).store;
  }
  return Orbit.use<T>(create);
}
