import 'package:args/command_runner.dart';
import 'package:droidkit/src/avd/avd_service.dart';
import 'package:droidkit/src/catalog/resolver.dart';
import 'package:droidkit/src/commands/droidkit_command.dart';
import 'package:droidkit/src/context.dart';
import 'package:mason_logger/mason_logger.dart';

/// `droidkit avd`.
class AvdCommand extends Command<int> {
  /// Creates an [AvdCommand].
  AvdCommand(ContextProvider context) {
    addSubcommand(AvdListCommand(context));
    addSubcommand(_AvdCreateCommand(context));
    addSubcommand(_AvdDeleteCommand(context));
    addSubcommand(_AvdDevicesCommand(context));
  }

  @override
  String get name => 'avd';

  @override
  String get description => 'Manage Android Virtual Devices (emulators).';
}

/// `droidkit avd list` (also available as `droidkit list`).
class AvdListCommand extends DroidkitCommand {
  /// Creates an [AvdListCommand].
  AvdListCommand(super.context, {this.alias = false});

  /// Whether this is the top-level `droidkit list` alias.
  final bool alias;

  @override
  String get name => 'list';

  @override
  String get description => alias
      ? 'List emulators (same as `droidkit avd list`).'
      : 'List emulators and whether they are running.';

  @override
  Future<int> run() async {
    maxArgs(0);
    final ctx = await context();
    final sdk = await ctx.sdk();
    final tools = await ctx.tools(sdk, needJava: false);
    final avds = await tools.listAvds();
    if (avds.isEmpty) {
      logger.info('No emulators yet. Create one with `droidkit avd create`.');
      return ExitCode.success.code;
    }
    final running = {
      for (final e in await tools.runningEmulators())
        if (e.avdName != null) e.avdName!: e.serial,
    };
    final service = AvdService(ctx);
    for (final name in avds) {
      final info = service.info(name);
      final serial = running[name];
      final isDefault = ctx.config.defaultAvd == name;
      logger.info(
        '${serial != null ? green.wrap('●')! : darkGray.wrap('○')!} '
        '${styleBold.wrap(name)}${isDefault ? ' (default)' : ''}'
        '${serial != null ? green.wrap('  running as $serial')! : ''}',
      );
      final details = [
        if (info.device != null) info.device!,
        if (info.systemImage != null) info.systemImage!,
      ];
      if (details.isNotEmpty) {
        logger.info('    ${darkGray.wrap(details.join('  •  '))}');
      }
    }
    return ExitCode.success.code;
  }
}

class _AvdCreateCommand extends DroidkitCommand {
  _AvdCreateCommand(super.context) {
    argParser
      ..addOption('name', abbr: 'n', help: 'Emulator name.')
      ..addOption(
        'api',
        help: 'Android API level (default: what your Flutter builds against).',
      )
      ..addOption(
        'image',
        help: 'System image tag.',
        defaultsTo: 'google_apis_playstore',
        allowedHelp: systemImageTags,
      )
      ..addOption(
        'device',
        abbr: 'd',
        help:
            'Device profile id (see `droidkit avd devices`). '
            'Can also be given as the first argument.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an emulator with the same name.',
      );
  }

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create an emulator (installs the emulator and system image if needed).';

  @override
  String get invocation => 'droidkit avd create [<device>] [options]';

  @override
  String get usageFooter => '''

Examples:
  droidkit avd create                         default Pixel phone
  droidkit avd create pixel_tablet            pick a device profile
  droidkit avd create pixel_tablet -n Tab     ...and name the emulator
  droidkit avd create --api 34 --image google_apis''';

  @override
  Future<int> run() async {
    maxArgs(1);
    final deviceFlag = argResults!['device'] as String?;
    if (rest.isNotEmpty && deviceFlag != null && deviceFlag != rest.first) {
      usageException(
        'Device given twice ("${rest.first}" and --device $deviceFlag).',
      );
    }
    final device = rest.isNotEmpty ? rest.first : deviceFlag;
    final ctx = await context();
    final apiArg = argResults!['api'] as String?;
    final api = apiArg == null ? null : int.tryParse(apiArg);
    if (apiArg != null && api == null) {
      usageException('--api must be a number.');
    }
    final installer = await this.installer();
    await installer.ensureJdk();
    final sdk = await ctx.sdk();
    await installer.ensureCmdlineTools(sdk);
    final name = await AvdService(ctx).create(
      sdk: sdk,
      api: api,
      tag: argResults!['image'] as String,
      device: device,
      name: argResults!['name'] as String?,
      force: argResults!['force'] as bool,
    );
    logger.info('Start it with: droidkit start $name');
    return ExitCode.success.code;
  }
}

class _AvdDeleteCommand extends DroidkitCommand {
  _AvdDeleteCommand(super.context);

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete an emulator and its data.';

  @override
  String get invocation => 'droidkit avd delete <name>';

  @override
  Future<int> run() async {
    if (rest.length != 1) usageException('Name exactly one emulator.');
    final name = rest.single;
    final ctx = await context();
    final sdk = await ctx.requireSdk();
    final tools = await ctx.tools(sdk);
    if (!(await tools.listAvds()).contains(name)) {
      throw DroidkitException(
        'No emulator named "$name".',
        hint: 'See `droidkit list`.',
        exitCode: ExitCode.usage,
      );
    }
    final running = (await tools.runningEmulators())
        .where((e) => e.avdName == name)
        .firstOrNull;
    if (!ctx.confirm('Delete $name and all its data?', defaultValue: false)) {
      return ExitCode.success.code;
    }
    if (running != null) {
      logger.info('Stopping $name first…');
      await tools.killEmulator(running.serial);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    final result = await tools.deleteAvd(name);
    if (!result.ok) {
      throw DroidkitException(
        'avdmanager could not delete $name:\n${result.stderr.trim()}',
      );
    }
    if (ctx.config.defaultAvd == name) {
      ctx.config.defaultAvd = null;
      ctx.saveConfig();
    }
    logger.success('Deleted $name');
    return ExitCode.success.code;
  }
}

class _AvdDevicesCommand extends DroidkitCommand {
  _AvdDevicesCommand(super.context) {
    argParser.addFlag(
      'all',
      negatable: false,
      help: 'Include TV, Wear, Automotive and XR profiles.',
    );
  }

  @override
  String get name => 'devices';

  @override
  String get description => 'List hardware profiles for `avd create --device`.';

  @override
  Future<int> run() async {
    maxArgs(0);
    final ctx = await context();
    final sdk = await ctx.requireSdk();
    final devices = await (await ctx.tools(sdk)).listDevices();
    final all = argResults!['all'] as bool;
    for (final d in devices.where((d) => all || d.tag == null)) {
      logger.info(
        '  ${d.id.padRight(28)} ${d.name}'
        '${d.tag != null ? darkGray.wrap('  [${d.tag}]') : ''}',
      );
    }
    return ExitCode.success.code;
  }
}
