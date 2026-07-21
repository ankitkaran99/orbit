# Orbit

A tiny Flutter state management library built around Flutter's own strengths — zero external dependencies, zero code generation, zero boilerplate.

Built entirely on Flutter SDK primitives: `ChangeNotifier`, `AnimatedBuilder`, and `InheritedNotifier` (the same primitives that power `AnimationController`, `ValueNotifier`, and `Theme.of(context)`).

---

## Installation

Add Orbit to your `pubspec.yaml`:

```yaml
dependencies:
  orbit:
    path: ../orbit
```

---

## Quick Start & Usage

### 1. Declare a Store

Store state is kept in **private fields** exposed via **public getters**. State modifications happen exclusively through `@protected` `mutate()` / `mutateAsync()` methods.

Computed values are plain Dart getters — no special syntax required.

```dart
import 'package:orbit/orbit.dart';

class CounterStore extends OrbitStore {
  int _count = 0;
  int get count => _count;

  // Computed properties are just getters
  int get doubleCount => _count * 2;
  bool get isEven => _count.isEven;

  // Synchronous mutation (label is auto-inferred as 'increment' if omitted)
  int increment() => mutate(() => ++_count);

  // Asynchronous mutation (explicit label override)
  Future<int> fetchAndSet(Future<int> Function() apiCall) async {
    return await mutateAsync(() async {
      _count = await apiCall();
      return _count;
    }, label: 'fetchAndSet');
  }

  @override
  Map<String, Object?> debugSnapshot() => {'count': _count};
}

// Define the store once for global access
final counterStore = defineStore(() => CounterStore());
```

---

### 2. Connect to Widgets (`OrbitBuilder`)

Rebuilds your widget tree whenever the store emits state changes:

```dart
OrbitBuilder<CounterStore>(
  store: counterStore,
  builder: (context, store, child) => Text('Count: ${store.count}'),
)
```

#### Optimizing Rebuilds with `child`
If part of your widget tree does not depend on store state, pass it to `child` to avoid reconstructing it on rebuilds (same pattern as Flutter's `AnimatedBuilder`):

```dart
OrbitBuilder<CounterStore>(
  store: counterStore,
  child: const Icon(Icons.touch_app),
  builder: (context, store, child) => Row(
    children: [
      child!, // Reused across rebuilds
      Text('Count: ${store.count}'),
    ],
  ),
)
```

---

### 3. Select Selective Slices (`OrbitSelector`)

Use `OrbitSelector` when a widget only cares about a specific slice of store state:

```dart
OrbitSelector<CounterStore, bool>(
  store: counterStore,
  selector: (store) => store.isEven,
  builder: (context, isEven) => Text(isEven ? 'Even' : 'Odd'),
)
```

#### Custom Equality Check
Pass `equals` for collections or custom types needing deep equality comparison:

```dart
OrbitSelector<CartStore, List<Item>>(
  store: cartStore,
  selector: (store) => store.items,
  equals: (prev, next) => const ListEquality<Item>().equals(prev, next),
  builder: (context, items) => ListView.builder(
    itemCount: items.length,
    itemBuilder: (context, index) => Text(items[index].name),
  ),
)
```

#### Ultra-Concise Syntax with `defineStore`
You can also invoke `.builder()` and `.select()` directly on your `defineStore` references:

```dart
// Rebuilds on any store change:
counterStore.builder(
  builder: (context, store, child) => Text('Count: ${store.count}'),
);

// Rebuilds only when the selected slice changes:
counterStore.select<bool>(
  selector: (store) => store.isEven,
  builder: (context, isEven) => Text(isEven ? 'Even' : 'Odd'),
);
```

---

### 4. Reading Stores via `BuildContext`

Inside callback handlers (like `onPressed` or `onChanged`), use `context.orbitRead<T>()` to access a store without subscribing the current widget to unnecessary rebuilds:

```dart
ElevatedButton(
  onPressed: () => context.orbitRead<CounterStore>().increment(),
  child: const Text('Increment'),
)
```

Inside an `OrbitScope`, `context.orbit<T>()` watches and subscribes the current context to the scoped store:

```dart
final formStore = context.orbit<FormStore>();
```

---

### 5. Use Stores Outside the Widget Tree

Call stores anywhere in your application — event handlers, background tasks, or isolate callbacks:

```dart
void onPressed() {
  counterStore().increment();
}
```

Or inspect existing store singletons without instantiating new ones:

```dart
final existing = Orbit.read<CounterStore>();
if (existing != null) {
  print(existing.count);
}
```

---

### 5. Scoped Stores (`OrbitScope`)

While global singletons are the default, `OrbitScope` lets you instantiate independent store instances bound to a widget subtree (ideal for modal dialogs, tab screens, or reusable components):

```dart
OrbitScope<FormStore>(
  create: () => FormStore(), // Use a constructor, not a defineStore ref
  child: const FormDialog(),
)
```

Inside the `OrbitScope` subtree, `OrbitBuilder` and `OrbitSelector` automatically look up the scoped instance.

#### Accessing Scoped Stores Directly
```dart
// Throws FlutterError if no OrbitScope<FormStore> is found above context
final formStore = OrbitScope.of<FormStore>(context, listen: false);

// Safely returns null if no OrbitScope<FormStore> exists
final maybeFormStore = OrbitScope.maybeOf<FormStore>(context, listen: false);
```

---

### 6. Lifecycle Hooks (`init`, `onDispose`, `onResume`)

Override lifecycle methods directly inside your `OrbitStore`:

```dart
class UserProfileStore extends OrbitStore {
  User? _user;
  User? get user => _user;

  @override
  Future<void> init() async {
    // Runs automatically upon first instantiation (sync or async)
    _user = await loadSavedUser();
  }

  @override
  void onDispose() {
    // Called when store is reset or OrbitScope is unmounted
    cancelSubscriptions();
  }

  @override
  void onResume() {
    // Called when app enters foreground (AppLifecycleState.resumed)
    refreshProfileData();
  }
}
```

#### Awaiting Initialization (`store.ready`)
```dart
final userStore = userProfileStore();
if (!userStore.isReady) {
  await userStore.ready; // Awaits async init() or rethrows init errors
}
```

---

### 7. Mutation Middleware & Debugging

Register middleware to observe all mutations across all stores (ideal for logging, analytics, and offline persistence):

```dart
final unsubscribe = Orbit.observe((store, mutation) {
  print('Action: ${mutation.action}');
  print('Notified Listeners: ${mutation.listenerCount}');
  print('State Diff: ${mutation.diff}');
});

// To remove the observer later:
unsubscribe();
```

#### Console Debug Logs & Change History
In debug mode (`kDebugMode`), Orbit automatically prints human-readable mutation logs:

```
[Orbit] CounterStore.increment — count: 0 → 1 — notified 2 listeners
```

Inspect the last 200 mutations anytime via `Orbit.changeLog`:

```dart
final history = Orbit.changeLog; // Unmodifiable list of recent mutations
Orbit.clearChangeLog();          // Clear history (e.g., in test tearDown)
Orbit.debugLogging = false;       // Turn off debug logging
```

---

### 8. Testing & Mocking

Swap stores with mock or fake implementations for widget testing:

```dart
void main() {
  setUp(() {
    Orbit.override<CounterStore>(FakeCounterStore());
  });

  tearDown(() {
    Orbit.resetAll(); // Clears all singletons and disposes active stores
  });

  testWidgets('renders fake counter store', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Fake Count: 42'), findsOneWidget);
  });
}
```

---

## API Summary Cheat Sheet

| Class / Method | Description |
| :--- | :--- |
| `OrbitStore` | Base store class with private state, `@protected mutate<R>()`, `init()`, `onDispose()`, and `onResume()`. |
| `defineStore(factory)` | Defines a typed reference (`OrbitStoreRef<T>`) to a global store. |
| `OrbitBuilder<T>` | Listens to store `T` and rebuilds on change. Supports `child` subtree caching. |
| `OrbitSelector<T, S>` | Listens to store `T` and rebuilds only when `selector(store)` value changes. Supports `equals`. |
| `OrbitScope<T>` | Scopes a store instance to a widget subtree. |
| `OrbitScope.of<T>(context)` | Retrieves nearest scoped store or throws error. |
| `OrbitScope.maybeOf<T>(context)` | Safe lookup for nearest scoped store (returns `null` if absent). |
| `Orbit.use<T>(factory)` | Accesses or creates the global singleton store for `T`. |
| `Orbit.read<T>()` | Reads registered global store `T` without instantiating it. |
| `Orbit.override<T>(instance)` | Replaces singleton `T` with a mock/test instance. |
| `Orbit.reset<T>()` / `resetAll()` | Disposes and removes registered store(s). |
| `Orbit.observe(callback)` | Registers global mutation middleware. |
| `Orbit.changeLog` | Holds the last 200 mutations recorded during debug mode. |

---

## Running Tests

Execute Orbit unit and widget tests:

```bash
flutter test
```
