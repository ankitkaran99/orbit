# Orbit

[![Flutter CI](https://github.com/ankitkaran99/orbit/actions/workflows/flutter.yml/badge.svg)](https://github.com/ankitkaran99/orbit/actions/workflows/flutter.yml)

A tiny Flutter state management library built around Flutter's own strengths — zero external dependencies, zero code generation, zero boilerplate.

Built entirely on Flutter SDK primitives: `ChangeNotifier`, `AnimatedBuilder`, and `InheritedNotifier` (the same primitives that power `AnimationController`, `ValueNotifier`, and `Theme.of(context)`).

---

## Installation

Add Orbit to your `pubspec.yaml`:

```yaml
dependencies:
  orbit_state: ^0.3.1
```

---

## Quick Start & Usage

### 1. Declare a Store

Store state is kept in **private fields** exposed via **public getters**. State modifications happen exclusively through `@protected` `mutate()` / `mutateAsync()` methods.

Computed values are plain Dart getters — no special syntax required.

```dart
import 'package:orbit_state/orbit.dart';

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

### 6. Scoped Stores (`OrbitScope`)

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

### 7. Lifecycle Hooks (`init`, `onDispose`, `onResume`)

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

### 8. Async & Caching Support (`FutureProvider`, `StreamProvider`, `AsyncValue`)

Orbit provides native support for handling asynchronous data states with built-in caching. You can subclass `FutureProvider` and `StreamProvider` as store classes, which allows you to define custom actions and computed values alongside your async states.

#### The `AsyncValue` State Wrapper
A sealed class representing the three states of an asynchronous operation:
- **`AsyncLoading`**: The operation is in progress.
- **`AsyncData(value)`**: The operation succeeded and holds the data.
- **`AsyncError(error, stackTrace)`**: The operation failed.

Use the `when` method to map these states directly to widgets:

```dart
// In your Widget tree:
userStore.builder(
  builder: (context, store, _) => store.state.when(
    data: (user) => Text('Hello ${user.name}'),
    loading: () => const CircularProgressIndicator(),
    error: (err, stack) => Text('Error loading user: $err'),
  ),
);
```

#### `FutureProvider<T>` Store Class
An `OrbitStore` that handles a `Future`. It automatically runs the future on first access, caches the result, and transitions the state from `AsyncLoading` to `AsyncData` or `AsyncError`.

You can subclass `FutureProvider` to create custom stores with additional async actions:

```dart
class UserProfileStore extends FutureProvider<User> {
  UserProfileStore(this.api, this.userId) : super(() => api.fetchUser(userId));

  final ApiService api;
  final String userId;

  // Custom action that performs a write, then refreshes the future cache
  Future<void> updateBio(String bio) async {
    await api.updateBio(userId, bio);
    await refresh(); // Re-runs the future and updates state
  }
}

// Define the store once for global access:
final userStore = defineStore(() => UserProfileStore(apiService, 'user-123'));
```

Use `store.refresh()` to trigger a reload (this transitions state back to `AsyncLoading` and re-runs the future):
```dart
ElevatedButton(
  onPressed: () => context.orbitRead<UserProfileStore>().refresh(),
  child: const Text('Refresh Profile'),
)
```

#### `StreamProvider<T>` Store Class
An `OrbitStore` that listens to a `Stream`. It updates its state as the stream emits values or errors, and automatically cancels its subscription when the store is disposed (e.g. when an `OrbitScope` is unmounted).

You can subclass `StreamProvider` to add custom sending actions:

```dart
class ChatStore extends StreamProvider<List<Message>> {
  ChatStore(this.chatService) : super(() => chatService.streamMessages());

  final ChatService chatService;

  // Custom action to send message and wait for stream updates
  Future<void> sendMessage(String text) async {
    await chatService.send(text);
  }
}

// Define the store:
final chatStore = defineStore(() => ChatStore(chatService));
```

---

### 9. Combining State (`ComputedStore`, `watch`)

Orbit provides native ways for stores to watch other stores, allowing you to combine state and react to changes either declaratively or imperatively.

#### Declarative: `ComputedStore<T>`
Ideal for read-only reactive derived values (analogous to Riverpod's `Provider`). It automatically tracks which stores are read inside its compute function and updates itself when any of its dependencies change:

```dart
final todoListStore = defineStore(() => TodoListStore());
final filterStore = defineStore(() => FilterStore());

final filteredTodosStore = defineStore(() => ComputedStore<List<Todo>>((watch) {
  final todos = watch(todoListStore).todos;
  final filter = watch(filterStore).filter;
  return todos.where((t) => t.matches(filter)).toList();
}));

// In your Widget tree, use it just like any other store:
filteredTodosStore.builder(
  builder: (context, store, _) => ListView(
    children: store.state.map((t) => TodoWidget(t)).toList(),
  ),
);
```

#### Imperative: `OrbitStore.watch`
For stateful stores, you can use the built-in `watch()` method to listen to changes on other stores. Orbit handles the subscription cleanup automatically when the watching store is disposed:

```dart
class SearchServiceStore extends OrbitStore {
  List<Result> results = [];

  @override
  void init() {
    watch(searchQueryStore, (queryStore) async {
      final query = queryStore.query;
      final newResults = await api.search(query);
      mutate(() {
        results = newResults;
      });
    });
  }
}
```

---

### 10. Side Effect Helpers (`debounce`, `throttle`)

Orbit provides built-in, memory-safe debouncing and throttling helpers directly on the `OrbitStore` class. These make it simple to implement common UI patterns (like search-as-you-type and submit rate-limiting) without worrying about manual timers or memory leaks.

#### Debounce
Delays execution of an action until a specified duration of inactivity has passed. Subsequent calls with the same `id` cancel the pending timer and schedule a new one:

```dart
class SearchStore extends OrbitStore {
  String query = '';
  List<Result> results = [];

  void updateQuery(String newQuery) {
    query = newQuery;
    
    // Wait 300ms of inactivity before firing the API request
    debounce('search_query', const Duration(milliseconds: 300), () async {
      final res = await api.search(query);
      mutate(() {
        results = res;
      });
    });
  }
}
```

#### Throttle
Executes an action immediately (leading-edge) and rate-limits subsequent calls with the same `id`, ignoring them entirely during the throttle window:

```dart
class PaymentStore extends OrbitStore {
  void submitPayment() {
    // Prevent duplicate charges by ignoring clicks for 2 seconds
    throttle('submit_payment', const Duration(seconds: 2), () async {
      await api.chargeUser();
    });
  }
}
```

Active timers are **automatically cancelled** when the store is disposed (e.g., when an `OrbitScope` is unmounted), guaranteeing that callback side-effects will never fire on a disposed store.

---

### 11. Mutation Middleware & Debugging

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

### 12. Compile-time Safety & Safe Lookups

Orbit prioritizes compile-time safety to prevent common state management bugs like `ProviderNotFoundException` or runtime lookup crashes. By utilizing `OrbitStoreRef` (returned from `defineStore`), you get crash-free context lookups.

#### Safe Fallback Lookups (`storeRef.of(context)`)
Instead of accessing stores by generic types, use your defined store reference to perform lookups. If a scoped store exists in an ancestor `OrbitScope`, it is resolved and subscribed to. If not, it automatically falls back to the global singleton (instantiating it on-the-fly if necessary).

This guarantees that the lookup will **never** throw a runtime exception:

```dart
// 1. Compile-time safe lookup (resolves scoped or falls back to global singleton)
final store = counterStore.of(context);

// 2. Read-only lookup (inside callbacks like onPressed, no rebuild dependency)
final storeRead = counterStore.of(context, listen: false);
```

#### BuildContext Overloads
The standard `BuildContext` extensions can also accept `OrbitStoreRef` parameters directly for type-safe, crash-free resolution with type inference:

```dart
// Subscribes context to store updates:
final store = context.orbit(counterStore);

// Read-only access:
final storeRead = context.orbitRead(counterStore);
```

---

### 13. Testing & Mocking

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
| `OrbitStore.watch(storeRef, onChange)` | Subscribes a store to changes in another global store and cleans up automatically on dispose. |
| `OrbitStore.debounce(id, duration, action)` | Executes an action after a specified duration of inactivity. Cancels pending execution when called again. |
| `OrbitStore.throttle(id, duration, action)` | Executes an action immediately and ignores subsequent calls for the specified duration. |
| `defineStore(factory)` | Defines a typed reference (`OrbitStoreRef<T>`) to a global store. |
| `OrbitStoreRef.of(context)` | Type-safe, crash-free lookup that returns scoped store or falls back to global singleton. |
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
| `FutureProvider<T>` | An `OrbitStore` that handles a `Future`, automatically caching its value and exposing state as an `AsyncValue`. |
| `StreamProvider<T>` | An `OrbitStore` that listens to a `Stream`, automatically updates its state, and cancels subscription when disposed. |
| `AsyncValue<T>` | A sealed class representing an async data state (`AsyncLoading`, `AsyncData`, `AsyncError`). Provides `when()` to map states. |
| `ComputedStore<T>` | An `OrbitStore` that computes derived, read-only state by watching other stores and re-evaluating when dependencies change. |

---

## Running Tests

Execute Orbit unit and widget tests:

```bash
flutter test
```
