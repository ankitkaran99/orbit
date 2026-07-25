part of '../orbit.dart';

/// Rebuilds [builder] whenever store [T] changes.
///
/// No provider setup, no wrapping your app in anything for the default
/// case — [store] is only used the very first time this store is
/// requested anywhere in the app; every widget asking for `T`
/// afterwards shares one instance. If this widget sits inside an
/// `OrbitScope<T>`, it automatically uses that scoped instance instead
/// — no change needed here.
///
/// ```dart
/// OrbitBuilder<CounterStore>(
///   store: () => CounterStore(),
///   builder: (context, store, child) => Text('${store.count}'),
/// )
/// ```
///
/// If part of your subtree doesn't depend on the store, pass it as
/// [child] instead of building it inline — like `AnimatedBuilder`, it's
/// built once and passed through on every rebuild instead of being
/// reconstructed each time the store changes.
class OrbitBuilder<T extends OrbitStore> extends StatelessWidget {
  const OrbitBuilder({
    super.key,
    required this.store,
    required this.builder,
    this.child,
  });

  /// Factory used only the first time this store type is requested
  /// globally. Ignored if an ancestor `OrbitScope<T>` provides one.
  final T Function() store;

  final Widget Function(BuildContext context, T store, Widget? child) builder;

  /// A subtree that doesn't depend on the store; built once and reused.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final instance = _resolveStore<T>(context, store);
    return AnimatedBuilder(
      animation: instance,
      builder: (context, child) => builder(context, instance, child),
      child: child,
    );
  }
}
