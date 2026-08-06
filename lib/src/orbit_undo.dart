part of orbit;

/// Represents a single record in Orbit's global undo/redo history.
class OrbitUndoEntry {
  OrbitUndoEntry({
    required this.store,
    required this.before,
    required this.after,
    this.label,
  });

  /// The store instance that was mutated (must mix in [Undoable]).
  final OrbitStore store;

  /// The state snapshot captured before the mutation ran.
  final Map<String, Object?> before;

  /// The state snapshot captured after the mutation completed.
  final Map<String, Object?> after;

  /// Optional action label of the mutation that produced this record.
  final String? label;
}

/// A mixin on [OrbitStore] that opts the store into global undo/redo support.
///
/// Stores mixing in [Undoable] must implement [restore] to restore state fields
/// from a previously captured state map (returned by [snapshot]).
mixin Undoable on OrbitStore {
  /// Applies a previously captured snapshot (from [OrbitStore.snapshot])
  /// back onto this store's fields. Called by Orbit.undo()/redo() —
  /// never call this directly.
  void restore(Map<String, Object?> state);

  @override
  R mutate<R>(R Function() action, {String? label}) {
    if (Orbit._isRestoring) {
      return super.mutate(action, label: label);
    }

    final before = snapshot();
    try {
      final result = super.mutate(action, label: label);
      if (result is Future) {
        return (result as Future).whenComplete(() {
          final after = snapshot();
          if (before != null && after != null) {
            Orbit._pushUndo(OrbitUndoEntry(
              store: this,
              before: before,
              after: after,
              label: label,
            ));
          }
        }) as R;
      }
      final after = snapshot();
      if (before != null && after != null) {
        Orbit._pushUndo(OrbitUndoEntry(
          store: this,
          before: before,
          after: after,
          label: label,
        ));
      }
      return result;
    } catch (error) {
      final after = snapshot();
      if (before != null && after != null) {
        Orbit._pushUndo(OrbitUndoEntry(
          store: this,
          before: before,
          after: after,
          label: label,
        ));
      }
      rethrow;
    }
  }
}
