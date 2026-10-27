import 'dart:io';

import 'package:args/args.dart';
import 'package:droidkit/src/avd/avd_service.dart';
import 'package:droidkit/src/catalog/models.dart';
import 'package:droidkit/src/catalog/resolver.dart';
import 'package:droidkit/src/commands/droidkit_command.dart';
import 'package:droidkit/src/commands/env_command.dart';
import 'package:droidkit/src/config/toolchain_lock.dart';
import 'package:droidkit/src/context.dart';
import 'package:droidkit/src/env/shell_profile.dart';
import 'package:droidkit/src/installer.dart';
import 'package:droidkit/src/java/jdk.dart';
import 'package:droidkit/src/sdk/android_sdk.dart';
import 'package:droidkit/src/util.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// `droidkit setup`.
class SetupCommand extends DroidkitCommand {
  /// Creates a [SetupCommand].
  SetupCommand(super.context) {
    argParser
      ..addOption(
        'api',
        help:
            'Android API level to install (default: what your Flutter '
            'builds against).',
      )
      ..addOption(
        'image',
        help: 'Emulator system image tag.',
        allowedHelp: systemImageTags,
      )
      ..addOption(
        'device',
        help: 'Emulator hardware profile (see `droidkit avd devices`).',
      )
      ..addOption('avd-name', help: 'Name for the emulator.')
      ..addFlag(
        'emulator',
        defaultsTo: true,
        help:
            'Install the emulator and create a virtual device. Use '
            '--no-emulator for SDK-only setups (CI, physical devices).',
      )
      ..addOption(
        'cmdline-tools',
        help:
            'Command-line tools version: "$flutterCompatibleCmdlineTools" '
            '(newest that Flutter\'s license check understands) or "latest".',
        defaultsTo: flutterCompatibleCmdlineTools,
      )
      ..addFlag(
        'ndk',
        negatable: false,
        help:
            'Also install the NDK version Flutter expects (needed for '
            'native plugins; Gradle otherwise downloads it on demand).',
      )
      ..addOption(
        'jdk',
        help:
            '"auto": use a suitable JDK or download one; "system": never '
            'download; or a path to a JDK home.',
        defaultsTo: 'auto',
      )
      ..addFlag(
        'persist-env',
        help:
            'Add ANDROID_HOME/JAVA_HOME/PATH to your shell profile. '
            'Asked interactively when not given.',
      )
      ..addFlag(
        'flutter-config',
        defaultsTo: true,
        help: 'Point Flutter at this SDK and JDK (`flutter config`).',
      );
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Install and configure everything needed to build and run Flutter apps '
      'on Android.';

  @override
  Future<int> run() async {
    maxArgs(0);
    final ctx = await context();
    final installer = Installer(ctx)..cleanTemp();
    final host = ctx.host;
    final lock = ctx.lock;
    final initLock = lock == null;
    final args = argResults!;

    final apiArg = args.option('api');
    final api = apiArg == null ? null : int.tryParse(apiArg);
    if (apiArg != null && api == null) {
      usageException('--api must be a number.');
    }

    logger.info(
      '${styleBold.wrap('droidkit setup')} — Android toolchain for Flutter '
      '(${host.description})\n',
    );
    if (lock != null && !lock.isEmpty) {
      logger.info('Using ${lock.path}');
    }

    var wantEmulator = args.preferFlag('emulator', lock?.emulator);
    if (wantEmulator && !host.supportsEmulator) {
      logger.warn('${host.emulatorUnsupportedReason} Continuing without it.');
      wantEmulator = false;
    }
    if (wantEmulator && host.isWsl) {
      logger.warn(
        'Running in WSL: the emulator can\'t use hardware acceleration '
        'here. Installing the SDK only; run droidkit on Windows for the '
        'emulator.',
      );
      wantEmulator = false;
    }

    // 1. SDK location -------------------------------------------------------
    final sdk = await _chooseSdk(ctx);

    // 2. JDK ----------------------------------------------------------------
    _step('Java');
    final jdk = await _chooseJdk(ctx, installer);
    logger.success('Using JDK ${jdk.versionString} (${jdk.home})');

    // 3. cmdline-tools + licenses -------------------------------------------
    _step('Android SDK');
    final cmdlineTools = args.preferOption(
      'cmdline-tools',
      lock?.cmdlineTools,
    )!;
    final replaceTools =
        (args.wasParsed('cmdline-tools') || lock?.cmdlineTools != null) &&
        sdk.hasCmdlineTools &&
        sdk.cmdlineToolsVersion != cmdlineTools &&
        cmdlineTools != 'latest';
    await installer.ensureCmdlineTools(
      sdk,
      version: cmdlineTools,
      replace: replaceTools,
    );
    logger.success(
      'Command-line tools ${sdk.cmdlineToolsVersion ?? ''} ready'.replaceAll(
        '  ',
        ' ',
      ),
    );
    final tools = await ctx.tools(sdk);
    await installer.acceptLicenses(tools);

    // 4. Packages -----------------------------------------------------------
    final targetApi =
        api ?? lock?.platform ?? await installer.flutterCompileSdk();
    final catalog = await ctx.catalogs.main();
    final resolver = PackageResolver(catalog, host);
    final platform = resolver.platformPath(targetApi);
    if (platform == null) {
      throw DroidkitException(
        'Android API $targetApi is not available.',
        hint:
            'Stable API levels: ${resolver.stablePlatformApis().take(8).join(', ')}',
        exitCode: ExitCode.usage,
      );
    }
    final buildTools = _buildToolsPath(lock, catalog, resolver);
    final packages = [
      if (host.supportsPlatformTools) 'platform-tools',
      platform,
      ?buildTools,
    ];
    String? ndkVersion;
    if (args.wasParsed('ndk') ? args['ndk'] as bool : lock?.ndk != null) {
      ndkVersion =
          lock?.ndk ??
          await ctx.flutter.defaultNdkVersion(
            (path) => File(path).readAsStringSync(),
          );
      if (ndkVersion == null) {
        logger.warn('Could not read Flutter\'s NDK version; skipping the NDK.');
      } else {
        packages.add('ndk;$ndkVersion');
      }
    }
    await installer.installPackages(tools, packages);
    if (!host.supportsPlatformTools) {
      logger.warn(
        'Google ships no adb for ${host.description}; install it from your '
        'package manager (e.g. `sudo apt install adb`).',
      );
    }

    // 5. Emulator -----------------------------------------------------------
    String? avdName;
    String? imageTag = args.preferOption('image', lock?.image);
    final deviceId = args.preferOption('device', lock?.device);
    final wantedAvd = args.preferOption('avd-name', lock?.avdName);
    if (wantEmulator) {
      _step('Emulator');
      final existing = await tools.listAvds();
      final pinned = wantedAvd == null ? null : sanitizeAvdName(wantedAvd);
      final reuse = pinned != null && existing.contains(pinned);
      final create =
          !reuse &&
          (existing.isEmpty ||
              args.wasParsed('avd-name') ||
              args.wasParsed('image') ||
              pinned != null ||
              ctx.confirm(
                'You already have ${existing.join(', ')}. Create another '
                'emulator?',
                defaultValue: false,
              ));
      if (create) {
        imageTag ??= ctx.choose(
          'Which kind of emulator?',
          choices: systemImageTags.keys.toList(),
          defaultValue: 'google_apis_playstore',
          display: (t) => '$t — ${systemImageTags[t]}',
        );
        avdName = await AvdService(ctx).create(
          sdk: sdk,
          api: targetApi,
          tag: imageTag,
          device: deviceId,
          name: wantedAvd,
        );
      } else {
        await installer.installPackages(tools, ['emulator']);
        avdName = reuse ? pinned : (ctx.config.defaultAvd ?? existing.first);
      }
      if (host.isLinux && !File('/dev/kvm').existsSync()) {
        logger.warn(
          '/dev/kvm is missing, so the emulator will be very slow. Enable '
          'virtualization in BIOS/UEFI; see `droidkit doctor`.',
        );
      }
    }

    // 6. Flutter + shell ----------------------------------------------------
    _step('Integration');
    if (argResults!['flutter-config'] as bool) {
      if (await ctx.flutter.executable() == null) {
        logger.info(
          'Flutter is not on PATH; skipping `flutter config`. Set '
          'ANDROID_HOME (below) so Flutter finds the SDK later.',
        );
      } else if (await ctx.flutter.configure(
        sdkRoot: sdk.root,
        jdkHome: jdk.source == 'PATH' ? null : jdk.home,
      )) {
        logger.success('Flutter now uses this SDK and JDK');
      } else {
        logger.warn('`flutter config` failed; run `droidkit doctor` later.');
      }
    }
    await _persistEnv(ctx);

    if (initLock) {
      final pinNoEmulator =
          args.wasParsed('emulator') && !(args['emulator'] as bool);
      final written = ToolchainLock(
        jdk: '${jdk.majorVersion}',
        cmdlineTools: sdk.cmdlineToolsVersion ?? cmdlineTools,
        platform: targetApi,
        buildTools: buildTools?.replaceFirst('build-tools;', ''),
        ndk: ndkVersion,
        emulator: pinNoEmulator ? false : null,
        image: wantEmulator ? imageTag : null,
        device: wantEmulator ? deviceId : null,
        avdName: wantEmulator ? avdName : null,
      ).save(ctx.fs);
      logger.info('Wrote $written');
    }

    // Done ------------------------------------------------------------------
    logger
      ..info('')
      ..success(styleBold.wrap('All set!'))
      ..info('Next steps:');
    if (avdName != null) logger.info('  droidkit start $avdName');
    logger
      ..info('  flutter run')
      ..info('  droidkit doctor    # verify everything');
    return ExitCode.success.code;
  }

  void _step(String title) =>
      logger.info('\n${styleBold.wrap(cyan.wrap('▸ $title'))}');

  String? _buildToolsPath(
    ToolchainLock? lock,
    SdkCatalog catalog,
    PackageResolver resolver,
  ) {
    final pinned = lock?.buildTools;
    if (pinned == null) return resolver.latestBuildTools()?.path;
    final path = 'build-tools;$pinned';
    if (catalog.find(path) == null) {
      throw DroidkitException(
        '$path is not in Google\'s SDK catalog.',
        hint: 'Check tools.build-tools in ${lock?.path ?? 'droidkit.toml'}.',
        exitCode: ExitCode.usage,
      );
    }
    return path;
  }

  Future<AndroidSdk> _chooseSdk(DroidkitContext ctx) async {
    _step('SDK location');
    final location = await ctx.sdkLocation();
    final sdk = await ctx.sdk();
    final existing = ctx.sdkLocator.looksLikeSdk(sdk.root);
    AndroidSdk chosen = sdk;
    if (existing) {
      logger.info(
        'Found an existing Android SDK at ${sdk.root} '
        '(${location.source}); reusing it.',
      );
    } else if (location.source == '--sdk-root') {
      logger.info('Installing the Android SDK into ${sdk.root}');
    } else {
      final root = ctx.prompt(
        'Where should the Android SDK go?',
        defaultValue: sdk.root,
      );
      chosen = AndroidSdk(
        p.normalize(p.absolute(_expandHome(root, ctx))),
        ctx.host,
        ctx.fs,
      );
      logger.info('Installing the Android SDK into ${chosen.root}');
    }
    if (chosen.root.contains(' ') && ctx.host.isWindows) {
      logger.warn(
        'The SDK path contains spaces, which breaks some NDK builds. '
        'Consider a path like C:\\Android\\Sdk.',
      );
    }
    if (!isWritable(chosen.root)) {
      throw DroidkitException(
        'Cannot write to ${chosen.root}.',
        hint: 'Choose another location with --sdk-root.',
        exitCode: ExitCode.noPerm,
      );
    }
    final wasManaged =
        ctx.config.managedSdk && ctx.config.sdkRoot == chosen.root;
    ctx.config
      ..sdkRoot = chosen.root
      ..managedSdk = wasManaged || !existing;
    ctx
      ..saveConfig()
      ..useSdkRoot(chosen.root);
    return chosen;
  }

  String _expandHome(String path, DroidkitContext ctx) =>
      path == '~' || path.startsWith('~/')
      ? ctx.host.homeDirectory + path.substring(1)
      : path;

  Future<Jdk> _chooseJdk(DroidkitContext ctx, Installer installer) async {
    final args = argResults!;
    if (!args.wasParsed('jdk')) {
      return installer.ensureJdk(major: ctx.lock?.jdkMajor);
    }
    final mode = args['jdk'] as String;
    switch (mode) {
      case 'auto':
        return installer.ensureJdk();
      case 'system':
        return ctx.requireJdk();
      default:
        final jdk = await ctx.jdkLocator.inspect(mode, '--jdk');
        if (jdk == null) {
          throw DroidkitException(
            'No Java installation at $mode.',
            hint: 'Pass the JDK home (the folder containing bin/java).',
            exitCode: ExitCode.usage,
          );
        }
        if (!jdk.isSupported) {
          throw DroidkitException(
            'The JDK at $mode ${jdk.problem}.',
            exitCode: ExitCode.usage,
          );
        }
        ctx
          ..jdkOverride = jdk
          ..config.jdkHome = jdk.home
          ..saveConfig();
        return jdk;
    }
  }

  Future<void> _persistEnv(DroidkitContext ctx) async {
    final shell = Shell.detect(ctx.host);
    final env = await toolchainEnvironment(ctx);
    final explicit = argResults!.wasParsed('persist-env')
        ? argResults!['persist-env'] as bool
        : null;
    final currentHome = ctx.host.environment['ANDROID_HOME'];
    final alreadySet =
        currentHome != null && p.normalize(currentHome) == env.sdkRoot;
    final persist =
        explicit ??
        (!alreadySet &&
            ctx.interactive &&
            !ctx.assumeYes &&
            logger.confirm(
              'Add ANDROID_HOME and the SDK tools to your PATH '
              '(${ctx.host.isWindows ? 'user environment variables' : ShellProfile(ctx.host, ctx.fs).rcFile(shell)})?',
              defaultValue: true,
            ));
    if (persist) {
      logger.success(await persistEnvironment(ctx, shell, env));
    } else if (!alreadySet) {
      logger.info(
        'To use adb/emulator/sdkmanager from your terminal, run '
        '`droidkit env --persist` (or add this to your shell profile):\n'
        '${darkGray.wrap(env.render(shell))}',
      );
    }
  }
}

extension on ArgResults {
  bool preferFlag(String name, bool? locked) {
    if (wasParsed(name)) return this[name] as bool;
    return locked ?? this[name] as bool;
  }

  String? preferOption(String name, String? locked) {
    if (wasParsed(name)) return this[name] as String?;
    return locked ?? this[name] as String?;
  }
}
