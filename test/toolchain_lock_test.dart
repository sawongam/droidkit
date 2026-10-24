import 'dart:io';

import 'package:droidkit/src/config/toolchain_lock.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers/helpers.dart';

void main() {
  test('parses droidkit.toml', () {
    final lock = ToolchainLock.parse('''
[tools]
jdk = "21.0.13+9"
cmdline-tools = "22.0"
platform = 36
build-tools = "37.0.0"

[emulator]
name = "flutter_emu"
''');
    expect(lock.jdkExact, '21.0.13+9');
    expect(lock.jdkMajor, isNull);
    expect(lock.cmdlineTools, '22.0');
    expect(lock.platform, 36);
    expect(lock.buildTools, '37.0.0');
    expect(lock.avdName, 'flutter_emu');

    final major = ToolchainLock.parse('[tools]\njdk = 21\n');
    expect(major.jdkMajor, 21);
    expect(major.jdkExact, isNull);

    expect(ToolchainLock.parse('emulator = false\n').emulator, isFalse);

    expect(
      () => ToolchainLock.parse('[tools]\nplatform = "api36"\n'),
      throwsFormatException,
    );
  });

  test('finds droidkit.toml in a parent directory', () {
    final root = tempDir(addTearDown);
    final nested = Directory(p.join(root.path, 'apps', 'mobile'))
      ..createSync(recursive: true);
    File(
      p.join(root.path, 'droidkit.toml'),
    ).writeAsStringSync('[tools]\nplatform = "35"\n');

    final lock = ToolchainLock.find(
      const LocalFileSystem(),
      startDir: nested.path,
    );
    expect(lock?.platform, 35);
    expect(lock?.path, p.join(root.path, 'droidkit.toml'));
  });
}
