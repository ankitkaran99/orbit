part of '../orbit.dart';

/// Ergonomic extensions on [BuildContext] for accessing and watching Orbit stores.
extension OrbitContextExtension on BuildContext {
  /// Accesses store [T] from the nearest [OrbitScope<T>] and subscribes
  /// this widget context to rebuild whenever state in store [T] changes.
  ///
  /// For listening to global singletons, use [OrbitBuilder] or `storeRef.builder()`.
  T orbit<T extends OrbitStore>() {
    return OrbitScope.of<T>(this, listen: true);
  }

  /// Accesses store [T] without subscribing this widget to rebuilds.
  ///
  /// Works with both scoped stores ([OrbitScope]) and global stores ([Orbit.use] / [defineStore]).
  /// Ideal inside callback handlers like `onPressed` or `onChanged`.
  T orbitRead<T extends OrbitStore>([T Function()? create]) {
    final scoped = OrbitScope.maybeOf<T>(this, listen: false);
    if (scoped != null) return scoped;
    final existing = Orbit.read<T>();
    if (existing != null) return existing;
    if (create != null) return Orbit.use<T>(create);
    throw FlutterError(
      'context.orbitRead<$T>() was called, but store $T is not created yet.\n'
      'Provide a factory: context.orbitRead<$T>(() => $T()), or wrap your app in '
      'OrbitScope<$T>, or define the store via defineStore.',
    );
  }
}
