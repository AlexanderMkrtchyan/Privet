import 'dart:async';

/// Leading+trailing throttle for bursty events (typing, pointer moves).
class Throttle {
  Throttle(this.interval);

  final Duration interval;
  DateTime? _last;
  Timer? _trailing;
  void Function()? _pending;

  /// Invoke [action] immediately if the interval has elapsed; otherwise
  /// schedule a trailing call with the latest [action].
  void call(void Function() action) {
    final now = DateTime.now();
    final last = _last;
    if (last == null || now.difference(last) >= interval) {
      _last = now;
      _trailing?.cancel();
      _pending = null;
      action();
      return;
    }
    _pending = action;
    _trailing?.cancel();
    final wait = interval - now.difference(last);
    _trailing = Timer(wait, () {
      final pending = _pending;
      _pending = null;
      if (pending == null) return;
      _last = DateTime.now();
      pending();
    });
  }

  void cancel() {
    _trailing?.cancel();
    _trailing = null;
    _pending = null;
  }

  /// Drop trailing work and allow the next [call] to fire immediately.
  void reset() {
    cancel();
    _last = null;
  }
}

/// Trailing-only debounce (draft persistence, inbox reconcile).
class Debouncer {
  Debouncer(this.delay);

  final Duration delay;
  Timer? _timer;

  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Run any pending action immediately (e.g. on dispose).
  void flush(void Function() action) {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    action();
  }

  bool get isArmed => _timer != null;
}
