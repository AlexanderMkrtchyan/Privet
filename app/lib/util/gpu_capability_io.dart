import 'dart:io';

bool? _cached;

/// One-shot GPU capability probe for native desktops / mobile.
///
/// Prefer cheap filesystem signals (NVIDIA/AMD device nodes). Fall back to a
/// single `glxinfo -B` parse when available. Never loops or samples frames.
Future<bool> hasCapableGpu() async {
  final hit = _cached;
  if (hit != null) return hit;
  return _cached = await _probe();
}

Future<bool> _probe() async {
  // Windows / Apple / Android: Impeller or the platform compositor owns the
  // GPU path. Never auto-strip motion there — LIBGL_* and /dev/dri probes are
  // Linux-only signals and must not flip "Low RAM & CPU" on a Windows box
  // (that freezes caret blink, typing dots, and big emoji together).
  if (Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isAndroid) {
    return true;
  }

  // Explicit software GL force → weak (Linux Mesa override).
  if (Platform.isLinux) {
    final alwaysSoft = Platform.environment['LIBGL_ALWAYS_SOFTWARE'];
    if (alwaysSoft == '1' || alwaysSoft == 'true') return false;
  }

  // Discrete NVIDIA / AMD device nodes — capable (e.g. RTX 3060).
  if (await _exists('/dev/nvidia0') ||
      await _exists('/proc/driver/nvidia/version') ||
      (await _exists('/dev/dri/by-path') && await _hasAmdOrNvidiaDri())) {
    return true;
  }

  // Linux without known discrete nodes: ask GL once.
  if (Platform.isLinux) {
    final renderer = await _glRenderer();
    if (renderer != null) {
      final r = renderer.toLowerCase();
      if (r.contains('llvmpipe') ||
          r.contains('softpipe') ||
          r.contains('swrast') ||
          r.contains('swiftshader') ||
          r.contains('microsoft basic render')) {
        return false;
      }
      // Any real vendor string → capable.
      if (r.contains('nvidia') ||
          r.contains('amd') ||
          r.contains('radeon') ||
          r.contains('intel') ||
          r.contains('mesa') ||
          r.contains('apple')) {
        // Mesa on llvmpipe already caught above; other Mesa = GPU.
        return true;
      }
    }
    // Unknown Linux GPU + little RAM → be conservative.
    final memKb = await _memTotalKb();
    if (memKb != null && memKb < 3 * 1024 * 1024) return false;
  }

  // Default: keep animations (user can toggle Low RAM & CPU).
  return true;
}

Future<bool> _exists(String path) async {
  try {
    return File(path).existsSync() || Directory(path).existsSync();
  } catch (_) {
    return false;
  }
}

Future<bool> _hasAmdOrNvidiaDri() async {
  try {
    final dir = Directory('/dev/dri/by-path');
    if (!dir.existsSync()) return false;
    await for (final e in dir.list()) {
      final n = e.path.toLowerCase();
      if (n.contains('nvidia') || n.contains('amd') || n.contains('radeon')) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

Future<String?> _glRenderer() async {
  try {
    final r = await Process.run(
      'glxinfo',
      const ['-B'],
      environment: {
        ...Platform.environment,
        // Avoid conda Mesa overrides when probing.
        '__EGL_VENDOR_LIBRARY_DIRS': '/usr/share/glvnd/egl_vendor.d',
      },
    ).timeout(const Duration(milliseconds: 800));
    if (r.exitCode != 0) return null;
    final out = '${r.stdout}';
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.toLowerCase().startsWith('opengl renderer')) {
        final i = t.indexOf(':');
        if (i >= 0) return t.substring(i + 1).trim();
      }
    }
  } catch (_) {}
  return null;
}

Future<int?> _memTotalKb() async {
  try {
    final lines = await File('/proc/meminfo').readAsLines();
    for (final line in lines) {
      if (line.startsWith('MemTotal:')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) return int.tryParse(parts[1]);
      }
    }
  } catch (_) {}
  return null;
}
