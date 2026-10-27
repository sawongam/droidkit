import 'package:file/file.dart';
import 'package:path/path.dart' as p;

/// File name searched upward from the working directory.
const toolchainLockFileName = 'droidkit.toml';

/// Project pin of the Android toolchain for `setup`.
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

  /// JDK major version, e.g. `21`.
  final String? jdk;

  /// `cmdline-tools` catalog version, e.g. `22.0`.
  final String? cmdlineTools;

  /// Android platform API level.
  final int? platform;

  /// Build-tools revision, e.g. `37.0.0`.
  final String? buildTools;

  /// NDK revision to install.
  final String? ndk;

  /// When `false`, setup skips the emulator. `null` leaves the CLI default.
  final bool? emulator;

  /// System image tag for the AVD.
  final String? image;

  /// Hardware profile for the AVD.
  final String? device;

  /// AVD name.
  final String? avdName;

  /// JDK major when [jdk] parses as an integer.
  int? get jdkMajor {
    final value = jdk;
    return value == null ? null : int.tryParse(value);
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
    final tables = _parse(source);
    final tools = tables['tools'] ?? const {};
    final emu = tables['emulator'] ?? const {};
    final root = tables[''] ?? const {};
    final file = path ?? toolchainLockFileName;

    return ToolchainLock(
      path: path,
      jdk: _jdkMajor(tools['jdk'], file),
      cmdlineTools: _string(tools['cmdline-tools']),
      platform: _apiLevel(tools['platform'], file),
      buildTools: _string(tools['build-tools']),
      ndk: _string(tools['ndk']),
      emulator: root['emulator'] is bool ? root['emulator'] as bool : null,
      image: _string(emu['image']),
      device: _string(emu['device']),
      avdName: _string(emu['name']),
    );
  }

  /// Writes this lock to [path] (default: `./droidkit.toml`).
  ///
  /// Throws if the file already exists.
  String save(FileSystem fs, {String? path}) {
    final out = p.normalize(
      p.absolute(path ?? p.join(p.current, toolchainLockFileName)),
    );
    final file = fs.file(out);
    if (file.existsSync()) {
      throw StateError('Refusing to overwrite $out');
    }

    final buf = StringBuffer('[tools]\n');
    if (jdk != null) buf.writeln('jdk = "${jdk!}"');
    if (cmdlineTools != null) {
      buf.writeln('cmdline-tools = "${cmdlineTools!}"');
    }
    if (platform != null) buf.writeln('platform = $platform');
    if (buildTools != null) buf.writeln('build-tools = "${buildTools!}"');
    if (ndk != null) buf.writeln('ndk = "${ndk!}"');

    if (emulator == false) {
      buf
        ..writeln()
        ..writeln('emulator = false');
    } else if (image != null || device != null || avdName != null) {
      buf
        ..writeln()
        ..writeln('[emulator]');
      if (image != null) buf.writeln('image = "${image!}"');
      if (device != null) buf.writeln('device = "${device!}"');
      if (avdName != null) buf.writeln('name = "${avdName!}"');
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$buf');
    return out;
  }

  static Map<String, Map<String, Object?>> _parse(String source) {
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
        throw FormatException('Invalid droidkit.toml line: $raw');
      }
      tables.putIfAbsent(current, () => {})[line.substring(0, eq).trim()] =
          _value(line.substring(eq + 1).trim());
    }
    return tables;
  }

  static Object? _value(String raw) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    if (RegExp(r'^-?\d+$').hasMatch(raw)) return int.parse(raw);
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      return raw.substring(1, raw.length - 1);
    }
    throw FormatException('Unsupported droidkit.toml value: $raw');
  }

  static int? _apiLevel(Object? value, String file) {
    if (value == null) return null;
    final parsed = value is int ? value : int.tryParse('$value');
    if (parsed != null) return parsed;
    throw FormatException(
      'Invalid tools.platform in $file: expected an API level, got "$value".',
    );
  }

  static String? _jdkMajor(Object? value, String file) {
    if (value == null) return null;
    final raw = value is int || value is String ? '$value' : null;
    if (raw != null && RegExp(r'^\d+$').hasMatch(raw)) return raw;
    throw FormatException(
      'Invalid tools.jdk in $file: expected a major version like "21", '
      'got "$value".',
    );
  }

  static String? _string(Object? value) {
    if (value == null) return null;
    if (value is String || value is int) return '$value';
    throw FormatException('Expected a string or number, got $value.');
  }
}
