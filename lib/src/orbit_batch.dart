part of '../orbit.dart';

/// Configuration for the Orbit debug-mode batch watchdog.
///
/// If a batch stays open longer than [warnAfter] (default 5 seconds) in debug mode,
/// [onWarning] is invoked with a warning message including the captured stack trace
/// from where the batch opened.
class OrbitBatchWatchdog {
  OrbitBatchWatchdog._();

  /// The duration after which an unclosed batch triggers a warning in debug mode.
  /// Defaults to 5 seconds.
  static Duration warnAfter = const Duration(seconds: 5);

  /// Callback invoked when a batch stays open longer than [warnAfter] in debug mode.
  /// Defaults to [print].
  static void Function(String message) onWarning = print;
}
