import 'package:flutter/material.dart';
import 'package:orbit/orbit.dart';

/// 1. Define a store: private fields + public getters, so state can
/// only change through mutate() — never by direct assignment from
/// outside the class.
class CounterStore extends OrbitStore {
  int _count = 0;

  int get count => _count;
  // Getters double as "computed" values — always fresh, no caching needed.
  int get doubleCount => _count * 2;
  bool get isEven => _count % 2 == 0;

  void increment() => mutate(() => _count++);
  void decrement() => mutate(() => _count--);

  // Optional: called once on first creation. Can be sync or async — here
  // it pretends to load a persisted starting value. The store is usable
  // immediately either way; await `counterStore().ready` if a widget
  // needs to know setup has actually finished.
  @override
  Future<void> init() async {
    await Future.delayed(const Duration(milliseconds: 200));
    _count = 0; // e.g. would come from shared_preferences / a repository
  }

  // Optional: cleanup when the store is disposed (e.g. Orbit.reset(),
  // or an OrbitScope unmounting).
  @override
  void onDispose() => debugPrint('CounterStore disposed');

  // Optional: powers Orbit.observe()/changeLog diffing. Without this,
  // logs still show which action ran, just not the field-level diff.
  @override
  Map<String, Object?> debugSnapshot() => {'count': _count};
}

// Declare the store once — every part of the app that reaches for
// `counterStore()` shares this exact factory, so there's no risk of two
// call sites silently disagreeing on how it's constructed.
final counterStore = defineStore(() => CounterStore());

void main() {
  // Mutation middleware — logging, analytics, persistence — without
  // touching store code. Runs in every build mode, not just debug.
  Orbit.observe((store, mutation) {
    // e.g. analytics.log(mutation.action, mutation.diff);
    debugPrint('observed: $mutation');
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Orbit demo')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 2. Watch the whole (global) store — rebuilds on every
              // mutate(). `child` is built once and reused across
              // rebuilds.
              counterStore.builder(
                child: const Icon(Icons.bolt), // static, never rebuilt
                builder: (context, store, child) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    child!,
                    Text(
                      ' Count: ${store.count} (double: ${store.doubleCount})',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 3. Or watch just a slice — only rebuilds when isEven flips.
              counterStore.select<bool>(
                selector: (store) => store.isEven,
                builder: (context, isEven) => Text(isEven ? 'Even' : 'Odd'),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ScopedCounterDialog(),
                ),
                child: const Text('Open scoped dialog'),
              ),
            ],
          ),
        ),
        floatingActionButton: Builder(
          builder: (context) {
            // 4. Reach the store from anywhere — no BuildContext needed
            //    for the logic itself, only if you want a rebuild.
            return FloatingActionButton(
              onPressed: counterStore().increment,
              child: const Icon(Icons.add),
            );
          },
        ),
      ),
    );
  }
}

/// 5. A dialog with its own independent CounterStore, scoped to this
/// subtree — completely separate from the global `counterStore` above.
/// Closing the dialog disposes it; opening it again starts fresh.
class _ScopedCounterDialog extends StatelessWidget {
  const _ScopedCounterDialog();

  @override
  Widget build(BuildContext context) {
    return OrbitScope<CounterStore>(
      create: () => CounterStore(), // a bare constructor, not counterStore()
      child: AlertDialog(
        title: const Text('Scoped counter'),
        content: OrbitBuilder<CounterStore>(
          // Ignored here — the ancestor OrbitScope<CounterStore> above
          // takes priority automatically.
          store: () => CounterStore(),
          builder: (context, store, _) => Text('Dialog count: ${store.count}'),
        ),
        actions: [
          Builder(
            builder: (context) => TextButton(
              onPressed: () => context.orbitRead<CounterStore>().increment(),
              child: const Text('+1 (dialog only)'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
