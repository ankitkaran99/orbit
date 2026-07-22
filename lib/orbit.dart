/// Orbit — a tiny, Pinia-style state management library for Flutter.
///
/// Zero external dependencies. Built entirely on top of Flutter's own
/// `ChangeNotifier`, `AnimatedBuilder`, and `InheritedNotifier` — the
/// same primitives that power `AnimationController`, `ValueNotifier`,
/// and `Theme.of(context)`-style lookups in the Flutter SDK.
library orbit;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

part 'src/orbit_store.dart';
part 'src/orbit_container.dart';
part 'src/orbit_mutation.dart';
part 'src/orbit_builder.dart';
part 'src/orbit_selector.dart';
part 'src/orbit_define.dart';
part 'src/orbit_scope.dart';
part 'src/orbit_context.dart';
part 'src/orbit_async.dart';
