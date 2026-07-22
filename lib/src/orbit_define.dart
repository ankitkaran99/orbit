part of '../orbit.dart';

/// A reference to a store, created once via [defineStore].
///
/// Calling it (`counterStore()`) returns the app-wide singleton, same as
/// `Orbit.use` — but because the factory lives in exactly one place,
/// it's impossible for two call sites to accidentally register the
/// store with different constructor arguments and silently get whichever
/// one happened to run first.
///
/// It's also directly usable wherever a `T Function()` is expected, so
/// it drops straight into `OrbitBuilder`/`OrbitSelector`'s `store:`
/// parameter.
class OrbitStoreRef<T extends OrbitStore> {
  const OrbitStoreRef(this._create);

  final T Function() _create;

  /// Returns the singleton instance, creating it on first access.
  T call() => Orbit.use<T>(_create);

  /// Returns an [OrbitBuilder] listening to this store.
  Widget builder({
    Key? key,
    required Widget Function(BuildContext context, T store, Widget? child)
        builder,
    Widget? child,
  }) {
    return OrbitBuilder<T>(
      key: key,
      store: _create,
      builder: builder,
      child: child,
    );
  }

  /// Returns an [OrbitSelector] listening to a selected slice of this store.
  Widget select<S>({
    Key? key,
    required S Function(T store) selector,
    required Widget Function(BuildContext context, S value) builder,
    bool Function(S previous, S next)? equals,
  }) {
    return OrbitSelector<T, S>(
      key: key,
      store: _create,
      selector: selector,
      builder: builder,
      equals: equals,
    );
  }

  /// Accesses this store from the nearest [OrbitScope], falling back
  /// to the app-wide singleton if no scope is found.
  ///
  /// Subscribes this widget context to rebuild whenever this store changes
  /// if [listen] is true (only applicable when resolved via [OrbitScope]).
  T of(BuildContext context, {bool listen = true}) {
    if (listen) {
      final scoped = context
          .dependOnInheritedWidgetOfExactType<_OrbitScopeInherited<T>>()
          ?.store;
      if (scoped != null) return scoped;
    } else {
      final element = context
          .getElementForInheritedWidgetOfExactType<_OrbitScopeInherited<T>>();
      if (element != null) {
        return (element.widget as _OrbitScopeInherited<T>).store;
      }
    }
    return Orbit.use<T>(_create);
  }
}

/// Declares a store once, Pinia-`defineStore`-style:
///
/// ```dart
/// final counterStore = defineStore(() => CounterStore());
///
/// // anywhere in the app:
/// counterStore().increment();
///
/// OrbitBuilder<CounterStore>(
///   store: counterStore,
///   builder: (context, store, child) => Text('${store.count}'),
/// )
/// ```
///
/// This is the recommended way to reach for a store — prefer it over
/// calling `Orbit.use<T>(() => T())` directly at each call site, since
/// only [defineStore]'s factory is guaranteed to run.
OrbitStoreRef<T> defineStore<T extends OrbitStore>(T Function() create) =>
    OrbitStoreRef<T>(create);
