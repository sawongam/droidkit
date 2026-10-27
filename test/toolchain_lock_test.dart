import 'dart:io';

import 'package:droidkit/src/config/toolchain_lock.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers/helpers.dart';

void main() {
  test('parses and saves droidkit.toml', () {
    final lock = ToolchainLock.parse('''
[tools]
jdk = "21"
cmdline-tools = "22.0"
platform = 36
build-tools = "37.0.0"

[emulator]
name = "flutter_emu"
''');
    expect(lock.jdkMajor, 21);
    expect(lock.cmdlineTools, '22.0');
    expect(lock.platform, 36);
    expect(lock.buildTools, '37.0.0');
    expect(lock.avdName, 'flutter_emu');
    expect(ToolchainLock.parse('emulator = false\n').emulator, isFalse);
    expect(
      () => ToolchainLock.parse('[tools]\nplatform = "api36"\n'),
      throwsFormatException,
    );
    expect(
      () => ToolchainLock.parse('[tools]\njdk = "21.0.13+9"\n'),
      throwsFormatException,
    );

    final dir = tempDir(addTearDown);
    const fs = LocalFileSystem();
    final path = lock.save(fs, path: p.join(dir.path, 'droidkit.toml'));
    final roundTrip = ToolchainLock.parse(
      fs.file(path).readAsStringSync(),
      path: path,
    );
    expect(roundTrip.jdkMajor, 21);
    expect(roundTrip.platform, 36);
    expect(roundTrip.avdName, 'flutter_emu');
  });

  test('save refuses to overwrite an existing file', () {
    final dir = tempDir(addTearDown);
    const fs = LocalFileSystem();
    final path = p.join(dir.path, 'droidkit.toml');
    const ToolchainLock(jdk: '21', platform: 36).save(fs, path: path);
    expect(
      () => const ToolchainLock(jdk: '17').save(fs, path: path),
      throwsStateError,
    );
    expect(fs.file(path).readAsStringSync(), contains('jdk = "21"'));
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
