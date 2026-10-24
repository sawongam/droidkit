import 'dart:io' as io;

import 'package:droidkit/src/catalog/catalog_repository.dart';
import 'package:droidkit/src/config/droidkit_config.dart';
import 'package:droidkit/src/config/toolchain_lock.dart';
import 'package:droidkit/src/host/host_platform.dart';
import 'package:droidkit/src/java/jdk.dart';
import 'package:droidkit/src/net/downloader.dart';
import 'package:droidkit/src/process/process_runner.dart';
import 'package:droidkit/src/sdk/android_sdk.dart';
import 'package:droidkit/src/sdk/sdk_locator.dart';
import 'package:droidkit/src/tools/android_tools.dart';
import 'package:droidkit/src/tools/flutter_tool.dart';
import 'package:droidkit/src/ui/task.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// Thrown by commands to stop with a user-facing error message.
class DroidkitException implements Exception {
  /// Creates a [DroidkitException].
  DroidkitException(this.message, {this.hint, this.exitCode});

  /// What went wrong.
  final String message;

  /// How to fix it.
  final String? hint;

  /// Process exit code (defaults to `ExitCode.software`).
  final ExitCode? exitCode;

  @override
  String toString() => message;
}

/// Shared services for every command. Built once per invocation.
class DroidkitContext {
  /// Creates a [DroidkitContext].
  DroidkitContext({
    required this.logger,
    required this.fs,
    required this.runner,
    required this.host,
    required this.paths,
    required this.downloader,
    required this.catalogs,
    required this.flutter,
    required this.assumeYes,
    required this.interactive,
    this.sdkRootOverride,
  });

  /// Output and prompts.
  final Logger logger;

  /// File system.
  final FileSystem fs;

  /// Runs external programs.
  final ProcessRunner runner;

  /// The machine we're on.
  final HostPlatform host;

  /// droidkit's own directories.
  final DroidkitPaths paths;

  /// Network access.
  final Downloader downloader;

  /// SDK catalogs.
  final CatalogRepository catalogs;

  /// The Flutter CLI.
  final FlutterTool flutter;

  /// `--yes`: answer every question with its default/"yes".
  final bool assumeYes;

  /// Whether we may prompt (a terminal is attached and not in CI).
  final bool interactive;

  /// `--sdk-root`.
  final String? sdkRootOverride;

  /// Whether the user accepted the SDK licenses during this run.
  bool licensesConsented = false;

  /// Persistent settings.
  late final DroidkitConfig config = DroidkitConfig.load(fs, paths);

  /// Project `droidkit.toml`, if found above the working directory.
  late final ToolchainLock? lock = ToolchainLock.find(fs);

  /// Saves [config].
  void saveConfig() => config.save(fs, paths);

  /// JDK discovery.
  late final JdkLocator jdkLocator = JdkLocator(
    host: host,
    fs: fs,
    runner: runner,
    droidkitJdkDir: paths.jdkDir,
  );

  /// SDK discovery.
  late final SdkLocator sdkLocator = SdkLocator(host, fs);

  SdkLocation? _sdkLocation;

  /// All places an SDK might be, in priority order.
  Future<List<SdkLocation>> sdkCandidates() async {
    final quick = sdkLocator.candidates(
      override: sdkRootOverride,
      configured: config.sdkRoot,
    );
    // Asking Flutter is slow (~1s); only do it if nothing else matched.
    if (sdkRootOverride != null ||
        quick.any(
          (c) =>
              c.source != 'default location' && sdkLocator.looksLikeSdk(c.root),
        )) {
      return quick;
    }
    final flutterSdk = (await flutter.config())['android-sdk'];
    return sdkLocator.candidates(
      configured: config.sdkRoot,
      flutterConfigured: flutterSdk,
    );
  }

  /// The SDK location droidkit works with.
  Future<SdkLocation> sdkLocation() async =>
      _sdkLocation ??= sdkLocator.choose(await sdkCandidates());

  /// Switches to the SDK at [root] (chosen during setup).
  void useSdkRoot(String root) =>
      _sdkLocation = SdkLocation(root, 'droidkit config');

  /// The SDK droidkit works with.
  Future<AndroidSdk> sdk() async =>
      AndroidSdk(p.normalize((await sdkLocation()).root), host, fs);

  /// The SDK, failing with a helpful message if it has no cmdline-tools.
  Future<AndroidSdk> requireSdk() async {
    final sdk = await this.sdk();
    if (!sdk.hasCmdlineTools) {
      throw DroidkitException(
        sdk.exists
            ? 'The Android SDK at ${sdk.root} has no command-line tools.'
            : 'No Android SDK found.',
        hint: 'Run `droidkit setup` (or `droidkit doctor --fix`).',
        exitCode: ExitCode.unavailable,
      );
    }
    return sdk;
  }

  Jdk? _jdk;
  bool _jdkLooked = false;

  /// The best usable JDK, or null.
  Future<Jdk?> jdk() async {
    if (!_jdkLooked) {
      _jdkLooked = true;
      _jdk = await jdkLocator.findBest(configured: config.jdkHome);
      _jdk ??= await jdkLocator.findBest(
        configured: config.jdkHome,
        flutterJdkDir: (await flutter.config())['jdk-dir'],
      );
    }
    return _jdk;
  }

  /// Overrides the JDK (after installing one).
  set jdkOverride(Jdk jdk) {
    _jdk = jdk;
    _jdkLooked = true;
  }

  /// The JDK, failing with a helpful message if there is none.
  Future<Jdk> requireJdk() async {
    final jdk = await this.jdk();
    if (jdk == null) {
      throw DroidkitException(
        'No suitable JDK ($minJavaVersion–$maxJavaVersion) found.',
        hint: 'Run `droidkit jdk install`, or set JAVA_HOME.',
        exitCode: ExitCode.unavailable,
      );
    }
    return jdk;
  }

  /// Environment for Android tools: JAVA_HOME and ANDROID_HOME set, the
  /// deprecated ANDROID_SDK_ROOT removed if it disagrees.
  Map<String, String> toolEnvironment(AndroidSdk sdk, Jdk? jdk) {
    final env = Map<String, String>.of(io.Platform.environment);
    env['ANDROID_HOME'] = sdk.root;
    if (env.containsKey('ANDROID_SDK_ROOT')) env['ANDROID_SDK_ROOT'] = sdk.root;
    if (jdk != null) {
      env['JAVA_HOME'] = jdk.home;
      final sep = host.isWindows ? ';' : ':';
      env['PATH'] = '${p.join(jdk.home, 'bin')}$sep${env['PATH'] ?? ''}';
    }
    return env;
  }

  /// Tool wrappers for [sdk].
  Future<AndroidTools> tools(AndroidSdk sdk, {bool needJava = true}) async =>
      AndroidTools(
        sdk: sdk,
        runner: runner,
        environment: toolEnvironment(
          sdk,
          needJava ? await requireJdk() : await jdk(),
        ),
      );

  /// Runs [body] while showing a spinner (only on a terminal, so piped output
  /// stays clean).
  Future<T> spinner<T>(String message, Future<T> Function() body) async {
    if (!io.stdout.hasTerminal) return body();
    final progress = Task(logger, message);
    try {
      return await body();
    } finally {
      progress.cancel();
    }
  }

  /// Asks a yes/no question. Returns [defaultValue] when non-interactive, and
  /// true when `--yes` was passed.
  bool confirm(String message, {bool defaultValue = true}) {
    if (assumeYes) return true;
    if (!interactive) return defaultValue;
    return logger.confirm(message, defaultValue: defaultValue);
  }

  /// Lets the user pick one of [choices]; returns [defaultValue] when not
  /// interactive.
  T choose<T extends Object>(
    String message, {
    required List<T> choices,
    required T defaultValue,
    String Function(T)? display,
  }) {
    if (assumeYes || !interactive || choices.length < 2) return defaultValue;
    return logger.chooseOne(
      message,
      choices: choices,
      defaultValue: defaultValue,
      display: display,
    );
  }

  /// Asks for free text; returns [defaultValue] when not interactive.
  String prompt(String message, {required String defaultValue}) {
    if (assumeYes || !interactive) return defaultValue;
    return logger.prompt(message, defaultValue: defaultValue).trim();
  }
}
