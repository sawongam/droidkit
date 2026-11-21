import 'dart:io';

import 'package:droidkit/src/catalog/resolver.dart';
import 'package:droidkit/src/context.dart';
import 'package:droidkit/src/installer.dart';
import 'package:droidkit/src/sdk/android_sdk.dart';
import 'package:droidkit/src/tools/android_tools.dart';
import 'package:droidkit/src/ui/task.dart';
import 'package:droidkit/src/util.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// Device profiles tried, in order, when the user doesn't pick one.
const preferredDevices = ['pixel_9', 'pixel_8', 'pixel_7', 'pixel_6', 'pixel'];

/// Settings droidkit applies to every AVD it creates (config.ini).
const avdDefaults = {
  'hw.keyboard': 'yes',
  'hw.gpu.enabled': 'yes',
  'hw.gpu.mode': 'auto',
  'showDeviceFrame': 'yes',
};

/// Details of an existing AVD read from its config files.
class AvdInfo {
  /// Creates an [AvdInfo].
  const AvdInfo({
    required this.name,
    required this.path,
    this.systemImage,
    this.device,
  });

  /// AVD name.
  final String name;

  /// Its `.avd` directory.
  final String? path;

  /// e.g. `system-images;android-36;google_apis_playstore;x86_64`.
  final String? systemImage;

  /// Device profile name, e.g. `Pixel 8`.
  final String? device;
}

/// Parses `key=value` ini files used by the emulator.
Map<String, String> parseIni(String content) => {
  for (final line in content.split('\n'))
    if (line.contains('=') && !line.trimLeft().startsWith('#'))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};

/// Updates (or adds) [values] in an ini file's [content].
String updateIni(String content, Map<String, String> values) {
  final remaining = Map.of(values);
  final lines = content.split('\n').map((line) {
    final eq = line.indexOf('=');
    if (eq < 0) return line;
    final key = line.substring(0, eq).trim();
    final value = remaining.remove(key);
    return value == null ? line : '$key=$value';
  }).toList();
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  for (final e in remaining.entries) {
    lines.add('${e.key}=${e.value}');
  }
  return '${lines.join('\n')}\n';
}

/// Creates and inspects AVDs.
class AvdService {
  /// Creates an [AvdService].
  AvdService(this.ctx);

  /// Shared services.
  final DroidkitContext ctx;

  Logger get _log => ctx.logger;

  /// The directory AVD definitions live in.
  String get avdHome {
    final env = ctx.host.environment;
    if (env['ANDROID_AVD_HOME'] case final v? when v.isNotEmpty) return v;
    if (env['ANDROID_USER_HOME'] case final v? when v.isNotEmpty) {
      return p.join(v, 'avd');
    }
    return p.join(ctx.host.homeDirectory, '.android', 'avd');
  }

  /// Reads details about [name].
  AvdInfo info(String name) {
    final ini = File(p.join(avdHome, '$name.ini'));
    String? path;
    if (ini.existsSync()) path = parseIni(ini.readAsStringSync())['path'];
    path ??= p.join(avdHome, '$name.avd');
    final config = File(p.join(path, 'config.ini'));
    if (!config.existsSync()) return AvdInfo(name: name, path: path);
    final values = parseIni(config.readAsStringSync());
    final sysdir = values['image.sysdir.1'];
    return AvdInfo(
      name: name,
      path: path,
      systemImage: sysdir
          ?.replaceAll(r'\', '/')
          .split('/')
          .where((s) => s.isNotEmpty)
          .join(';'),
      device: values['hw.device.name'],
    );
  }

  /// Picks a phone device profile.
  static String? defaultDevice(List<DeviceProfile> devices) {
    final ids = {for (final d in devices) d.id};
    for (final id in preferredDevices) {
      if (ids.contains(id)) return id;
    }
    final phones = devices.where(
      (d) => d.tag == null && d.id.startsWith('pixel'),
    );
    return phones.lastOrNull?.id;
  }

  /// Creates an AVD, installing the emulator and system image if needed.
  /// Returns the AVD name.
  Future<String> create({
    required AndroidSdk sdk,
    int? api,
    String tag = 'google_apis_playstore',
    String? device,
    String? name,
    bool force = false,
  }) async {
    final host = ctx.host;
    if (!host.supportsEmulator) {
      throw DroidkitException(
        host.emulatorUnsupportedReason!,
        exitCode: ExitCode.unavailable,
      );
    }
    final installer = Installer(ctx);
    final targetApi = api ?? await installer.flutterCompileSdk();

    final progress = Task(
      _log,
      'Finding a $tag system image for API $targetApi',
    );
    final catalog = await ctx.catalogs.systemImages(tags: {tag});
    final resolver = PackageResolver(catalog, host);
    final image = resolver.systemImage(api: targetApi, tag: tag);
    if (image == null) {
      progress.fail(
        'No $tag image for API $targetApi on ${host.arch.systemImageAbi}',
      );
      final available = resolver
          .systemImages(tag: tag)
          .map(PackageResolver.apiOf)
          .whereType<int>()
          .toSet()
          .take(8);
      throw DroidkitException(
        'No stable $tag system image for API $targetApi '
        '(${host.arch.systemImageAbi}).',
        hint: available.isEmpty
            ? 'Try another --image tag; see `droidkit images`.'
            : 'Available API levels for $tag: ${available.join(', ')}.',
        exitCode: ExitCode.usage,
      );
    }
    progress.complete('Using ${image.path}');

    final tools = await ctx.tools(sdk);
    final needed = [
      if (host.supportsPlatformTools) 'platform-tools',
      'emulator',
      image.path,
    ];
    if (!sdk.isInstalled(image.path)) {
      await installer.ensureDiskSpace(
        sdk.root,
        image.sizeFor(host) ?? 0,
        image.path,
      );
    }
    await installer.acceptLicenses(tools);
    await installer.installPackages(tools, needed);

    final devices = await tools.listDevices();
    // Accept any casing (`Pixel_Tablet` → `pixel_tablet`).
    final matched = device == null
        ? null
        : (devices.where((d) => d.id == device).firstOrNull ??
              devices
                  .where((d) => d.id.toLowerCase() == device.toLowerCase())
                  .firstOrNull);
    if (device != null && devices.isNotEmpty && matched == null) {
      throw DroidkitException(
        'Unknown device profile "$device".',
        hint: 'Run `droidkit avd devices` to list profiles.',
        exitCode: ExitCode.usage,
      );
    }
    final deviceId = matched?.id ?? device ?? defaultDevice(devices);
    final deviceName = devices.where((d) => d.id == deviceId).firstOrNull?.name;

    final existing = await tools.listAvds();
    var avdName = sanitizeAvdName(
      name ?? '${deviceName ?? deviceId ?? 'Phone'}_API_$targetApi',
    );
    var overwrite = force;
    if (existing.contains(avdName) && !force) {
      overwrite =
          ctx.interactive &&
          !ctx.assumeYes &&
          _log.confirm('An emulator named $avdName exists. Replace it?');
      if (!overwrite) {
        var i = 2;
        while (existing.contains('${avdName}_$i')) {
          i++;
        }
        avdName = '${avdName}_$i';
      }
    }

    final create = Task(_log, 'Creating emulator $avdName');
    final result = await tools.createAvd(
      name: avdName,
      systemImage: image.path,
      device: deviceId,
      force: overwrite,
    );
    if (!result.ok) {
      create.fail('avdmanager failed');
      throw DroidkitException(
        'Could not create $avdName:\n'
                '${result.stderr.trim()}\n${result.stdout.trim()}'
            .trim(),
      );
    }
    final config = File(p.join(info(avdName).path!, 'config.ini'));
    if (config.existsSync()) {
      config.writeAsStringSync(
        updateIni(config.readAsStringSync(), avdDefaults),
      );
    }
    create.complete('Created emulator $avdName');
    ctx.config.defaultAvd ??= avdName;
    ctx.saveConfig();
    return avdName;
  }
}
