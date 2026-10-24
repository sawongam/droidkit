import 'dart:io';

import 'package:droidkit/src/config/toolchain_lock.dart';
import 'package:droidkit/src/context.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers/helpers.dart';

void main() {
  test('parses a mise-style droidkit.toml', () {
    final lock = ToolchainLock.parse('''
# pin like mise.toml
emulator = false

[tools]
jdk = "21.0.13+9"
cmdline-tools = "22.0"
platform = 36
build-tools = "37.0.0"
ndk = "27.0.12077973"

[emulator]
image = "google_apis_playstore"
device = "pixel_9"
name = "flutter_emu"
''', path: '/proj/droidkit.toml');

    expect(lock.path, '/proj/droidkit.toml');
    expect(lock.jdk, '21.0.13+9');
    expect(lock.jdkMajor, isNull);
    expect(lock.jdkExact, '21.0.13+9');
    expect(lock.cmdlineTools, '22.0');
    expect(lock.platform, 36);
    expect(lock.buildTools, '37.0.0');
    expect(lock.ndk, '27.0.12077973');
    expect(lock.emulator, isFalse);
    expect(lock.image, 'google_apis_playstore');
    expect(lock.device, 'pixel_9');
    expect(lock.avdName, 'flutter_emu');
  });

  test('treats a bare jdk integer as a major', () {
    final lock = ToolchainLock.parse('''
[tools]
jdk = 21
''');
    expect(lock.jdk, '21');
    expect(lock.jdkMajor, 21);
    expect(lock.jdkExact, isNull);
  });

  test('finds droidkit.toml by walking parents', () {
    final root = tempDir(addTearDown);
    final nested = Directory(p.join(root.path, 'apps', 'mobile'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'droidkit.toml')).writeAsStringSync('''
[tools]
platform = "35"
''');

    final lock = ToolchainLock.find(
      const LocalFileSystem(),
      startDir: nested.path,
    );
    expect(lock, isNotNull);
    expect(lock!.platform, 35);
    expect(lock.path, p.join(root.path, 'droidkit.toml'));
  });

  test('rejects bad platform values', () {
    expect(
      () => ToolchainLock.parse('[tools]\nplatform = "api36"\n'),
      throwsA(isA<DroidkitException>()),
    );
  });
}
