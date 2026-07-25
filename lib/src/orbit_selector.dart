part of '../orbit.dart';

/// Like `OrbitBuilder`, but only rebuilds when the value returned by
/// [selector] actually changes — useful when a store holds a lot of
/// state but a given widget only cares about one slice of it. Also
/// picks up an ancestor `OrbitScope<T>` automatically, same as
/// `OrbitBuilder`.
///
/// ```dart
/// OrbitSelector<CounterStore, int>(
///   store: () => CounterStore(),
///   selector: (store) => store.count,
///   builder: (context, count) => Text('$count'),
/// )
/// ```
///
/// Note: keep [selector] referentially stable across rebuilds where
/// possible (e.g. a top-level or static function, or a `const`-friendly
/// tear-off) rather than a fresh closure built from local state — this
/// widget doesn't re-run [selector] on every parent rebuild, only when
/// the store notifies, so it assumes the same store maps to the same
/// derived value each time.
///
/// By default the selected value is compared with `==`; pass [equals]
/// for value types that need custom comparison (e.g. deep list/map
/// equality).
class OrbitSelector<T extends OrbitStore, S> extends StatefulWidget {
  const OrbitSelector({
    super.key,
    required this.store,
    required this.selector,
    required this.builder,
    this.equals,
  });

  final T Function() store;
  final S Function(T store) selector;
  final Widget Function(BuildContext context, S value) builder;

  /// Custom equality check used to decide whether to rebuild. Defaults
  /// to `==`.
  final bool Function(S previous, S next)? equals;

  @override
  State<OrbitSelector<T, S>> createState() => _OrbitSelectorState<T, S>();
}

class _OrbitSelectorState<T extends OrbitStore, S>
    extends State<OrbitSelector<T, S>> {
  T? _instance;
  late S _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateInstance();
  }

  @override
  void didUpdateWidget(OrbitSelector<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateInstance();
  }

  void _updateInstance() {
    final newInstance = _resolveStore<T>(context, widget.store);
    if (_instance != newInstance) {
      _instance?.removeListener(_onNotify);
      _instance = newInstance;
      _value = widget.selector(newInstance);
      newInstance.addListener(_onNotify);
    } else {
      final next = widget.selector(newInstance);
      final isEqual = widget.equals?.call(_value, next) ?? (_value == next);
      if (!isEqual) {
        _value = next;
      }
    }
  }

  void _onNotify() {
    final instance = _instance;
    if (instance == null) return;
    final next = widget.selector(instance);
    final isEqual = widget.equals?.call(_value, next) ?? (_value == next);
    if (!isEqual && mounted) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final postNext = widget.selector(instance);
            final postIsEqual =
                widget.equals?.call(_value, postNext) ?? (_value == postNext);
            if (!postIsEqual) {
              setState(() => _value = postNext);
            }
          }
        });
      } else {
        setState(() => _value = next);
      }
    }
  }

  @override
  void dispose() {
    _instance?.removeListener(_onNotify);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
