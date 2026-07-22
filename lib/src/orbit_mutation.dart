part of '../orbit.dart';

/// A single recorded mutation, produced by [OrbitStore.mutate] /
/// [OrbitStore.mutateAsync] and passed to every `Orbit.observe`
/// callback (and, in debug builds, to [Orbit.changeLog]).
class OrbitMutation {
  OrbitMutation({
    required this.store,
    required this.timestamp,
    required this.listenerCount,
    this.action,
    this.before,
    this.after,
  });

  /// The store instance that changed. Already reflects the *new* state
  /// — `mutate()` runs the mutation before building this object — so
  /// middleware (persistence, analytics) can just read live fields off
  /// it directly instead of relying on [before]/[after].
  final OrbitStore store;

  /// The label passed to `mutate(..., label: ...)`, if any.
  final String? action;

  /// When this mutation was recorded.
  final DateTime timestamp;

  /// How many widgets/listeners were subscribed to [store] at the time
  /// of this mutation (via `OrbitBuilder`, `OrbitSelector`,
  /// `OrbitScope`, or a manual `addListener`). An approximation of "how
  /// many places will re-render" — `OrbitSelector` may still skip an
  /// actual rebuild if its selected value didn't change.
  final int listenerCount;

  /// Snapshot taken just before the mutation, if the store overrides
  /// [OrbitStore.debugSnapshot].
  final Map<String, Object?>? before;

  /// Snapshot taken just after the mutation, if the store overrides
  /// [OrbitStore.debugSnapshot].
  final Map<String, Object?>? after;

  /// Just the fields that actually changed, as `field: (old, new)`.
  /// Empty if [OrbitStore.debugSnapshot] wasn't overridden, or nothing
  /// actually changed.
  late final Map<String, (Object?, Object?)> diff = _computeDiff();

  Map<String, (Object?, Object?)> _computeDiff() {
    if (before == null || after == null) return const {};
    final changed = <String, (Object?, Object?)>{};
    final keys = {...before!.keys, ...after!.keys};
    for (final key in keys) {
      final oldValue = before![key];
      final newValue = after![key];
      if (oldValue != newValue) changed[key] = (oldValue, newValue);
    }
    return Map.unmodifiable(changed);
  }

  @override
  String toString() {
    final label = action == null
        ? '${store.runtimeType}'
        : '${store.runtimeType}.$action';
    final buffer = StringBuffer('[Orbit] $label');
    if (before != null && after != null) {
      final changed = diff;
      buffer.write(changed.isEmpty
          ? ' (no field changes)'
          : ' \u2014 ${changed.entries.map((e) => '${e.key}: ${e.value.$1} \u2192 ${e.value.$2}').join(', ')}');
    }
    buffer.write(
        ' \u2014 notified $listenerCount listener${listenerCount == 1 ? '' : 's'}');
    return buffer.toString();
  }
}
