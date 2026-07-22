part of '../orbit.dart';

/// Ergonomic extensions on [BuildContext] for accessing and watching Orbit stores.
extension OrbitContextExtension on BuildContext {
  /// Accesses store [T] from the nearest [OrbitScope<T>], falling back to the global singleton
  /// if a [storeRef] is provided, and subscribes this widget context to rebuild on changes.
  T orbit<T extends OrbitStore>([OrbitStoreRef<T>? storeRef]) {
    if (storeRef != null) {
      return storeRef.of(this, listen: true);
    }
    return OrbitScope.of<T>(this, listen: true);
  }

  /// Accesses store [T] without subscribing this widget to rebuilds.
  ///
  /// Works with both scoped stores ([OrbitScope]) and global stores ([Orbit.use] / [defineStore]).
  T orbitRead<T extends OrbitStore>([OrbitStoreRef<T>? storeRef]) {
    if (storeRef != null) {
      return storeRef.of(this, listen: false);
    }

    final scoped = OrbitScope.maybeOf<T>(this, listen: false);
    if (scoped != null) return scoped;
    final existing = Orbit.read<T>();
    if (existing != null) return existing;
    throw FlutterError(
      'context.orbitRead<$T>() was called, but store $T is not created yet.\n'
      'Provide a store ref: context.orbitRead(counterStore), or wrap your app in '
      'OrbitScope<$T>, or define the store via defineStore.',
    );
  }
}
