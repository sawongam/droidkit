import 'package:droidkit/src/context.dart';
import 'package:file/file.dart';
import 'package:path/path.dart' as p;

/// File name searched upward from the working directory.
const toolchainLockFileName = 'droidkit.toml';

/// Project-level pin of the Android toolchain, analogous to `mise.toml`.
///
/// ```toml
/// [tools]
/// jdk = "21"                 # major, or an exact Temurin version e.g. "21.0.13+9"
/// cmdline-tools = "22.0"
/// platform = "36"
/// build-tools = "37.0.0"
/// ndk = "27.0.12077973"      # optional
///
/// [emulator]
/// image = "google_apis_playstore"
/// device = "pixel_9"
/// name = "flutter_emu"
/// ```
///
/// Set `emulator = false` at the root to skip the emulator. Explicit CLI flags
/// override values from this file.
class ToolchainLock {
  /// Creates a [ToolchainLock].
  const ToolchainLock({
    this.path,
    this.jdk,
    this.cmdlineTools,
    this.platform,
    this.buildTools,
    this.ndk,
    this.emulator,
    this.image,
    this.device,
    this.avdName,
  });

  /// Absolute path of the file that was loaded, if any.
  final String? path;

  /// Temurin major (`21`) or exact Adoptium semver (`21.0.13+9`).
  final String? jdk;

  /// `cmdline-tools` catalog version, e.g. `22.0` or `latest`.
  final String? cmdlineTools;

  /// Android platform API level.
  final int? platform;

  /// Build-tools revision, e.g. `37.0.0`.
  final String? buildTools;

  /// NDK revision to install, e.g. `27.0.12077973`.
  final String? ndk;

  /// When `false`, setup skips the emulator. `null` leaves the CLI default.
  final bool? emulator;

  /// System image tag for the AVD.
  final String? image;

  /// Hardware profile for the AVD.
  final String? device;

  /// AVD name.
  final String? avdName;

  /// JDK major when [jdk] is a bare integer; otherwise `null`.
  int? get jdkMajor {
    final value = jdk;
    if (value == null) return null;
    return int.tryParse(value);
  }

  /// Exact Temurin version when [jdk] is not a bare major; otherwise `null`.
  String? get jdkExact {
    final value = jdk;
    if (value == null || int.tryParse(value) != null) return null;
    return value;
  }

  /// Whether any field is set.
  bool get isEmpty =>
      jdk == null &&
      cmdlineTools == null &&
      platform == null &&
      buildTools == null &&
      ndk == null &&
      emulator == null &&
      image == null &&
      device == null &&
      avdName == null;

  /// Walks from [startDir] (or the process cwd) toward the filesystem root.
  static ToolchainLock? find(
    FileSystem fs, {
    String? startDir,
    String fileName = toolchainLockFileName,
  }) {
    var dir = fs.directory(p.normalize(p.absolute(startDir ?? p.current)));
    while (true) {
      final file = dir.childFile(fileName);
      if (file.existsSync()) {
        return parse(file.readAsStringSync(), path: file.path);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Parses [source] as a [ToolchainLock].
  static ToolchainLock parse(String source, {String? path}) {
    final tables = _parseTomlTables(source);
    final tools = tables['tools'] ?? const {};
    final emu = tables['emulator'] ?? const {};
    final root = tables[''] ?? const {};

    int? platform;
    final platformRaw = tools['platform'];
    if (platformRaw is int) {
      platform = platformRaw;
    } else if (platformRaw is String) {
      platform = int.tryParse(platformRaw);
      if (platform == null) {
        throw DroidkitException(
          'Invalid tools.platform in ${path ?? 'droidkit.toml'}: '
          'expected an API level, got "$platformRaw".',
        );
      }
    }

    final jdkRaw = tools['jdk'];
    final String? jdk;
    if (jdkRaw == null) {
      jdk = null;
    } else if (jdkRaw is int || jdkRaw is String) {
      jdk = '$jdkRaw';
    } else {
      throw DroidkitException(
        'Invalid tools.jdk in ${path ?? 'droidkit.toml'}.',
      );
    }

    return ToolchainLock(
      path: path,
      jdk: jdk,
      cmdlineTools: _string(tools['cmdline-tools']),
      platform: platform,
      buildTools: _string(tools['build-tools']),
      ndk: _string(tools['ndk']),
      emulator: root['emulator'] is bool ? root['emulator'] as bool : null,
      image: _string(emu['image']),
      device: _string(emu['device']),
      avdName: _string(emu['name']),
    );
  }

  static String? _string(Object? value) {
    if (value == null) return null;
    if (value is String || value is int) return '$value';
    throw DroidkitException('Expected a string or number, got $value.');
  }
}

/// Tables keyed by name; the root table uses the empty string.
Map<String, Map<String, Object?>> _parseTomlTables(String source) {
  final tables = <String, Map<String, Object?>>{'': {}};
  var current = '';

  for (var raw in source.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final comment = line.indexOf(' #');
    if (comment != -1) line = line.substring(0, comment).trimRight();

    final header = RegExp(r'^\[([A-Za-z0-9_-]+)\]$').firstMatch(line);
    if (header != null) {
      current = header.group(1)!;
      tables.putIfAbsent(current, () => {});
      continue;
    }

    final eq = line.indexOf('=');
    if (eq == -1) {
      throw DroidkitException('Invalid droidkit.toml line: $raw');
    }
    final key = line.substring(0, eq).trim();
    final value = _parseTomlValue(line.substring(eq + 1).trim());
    tables.putIfAbsent(current, () => {})[key] = value;
  }
  return tables;
}

Object? _parseTomlValue(String raw) {
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  if (RegExp(r'^-?\d+$').hasMatch(raw)) return int.parse(raw);
  if ((raw.startsWith('"') && raw.endsWith('"')) ||
      (raw.startsWith("'") && raw.endsWith("'"))) {
    return raw.substring(1, raw.length - 1);
  }
  throw DroidkitException('Unsupported droidkit.toml value: $raw');
}
