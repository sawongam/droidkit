import 'dart:convert';
import 'dart:io';

import 'package:droidkit/src/archive/extractor.dart';
import 'package:droidkit/src/catalog/models.dart';
import 'package:droidkit/src/catalog/resolver.dart';
import 'package:droidkit/src/context.dart';
import 'package:droidkit/src/host/host_platform.dart';
import 'package:droidkit/src/java/jdk.dart';
import 'package:droidkit/src/net/downloader.dart';
import 'package:droidkit/src/sdk/android_sdk.dart';
import 'package:droidkit/src/tools/android_tools.dart';
import 'package:droidkit/src/ui/task.dart';
import 'package:droidkit/src/util.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// The license every SDK package needs.
const defaultLicense = 'android-sdk-license';

/// compileSdk used when the installed Flutter can't be inspected (Flutter
/// 3.47's default).
const fallbackCompileSdk = 36;

/// A JDK build offered by Adoptium.
class AdoptiumRelease {
  /// Creates an [AdoptiumRelease].
  const AdoptiumRelease({
    required this.version,
    required this.url,
    required this.sha256,
    required this.size,
    required this.fileName,
  });

  /// Parses the Adoptium `assets/latest` response.
  static AdoptiumRelease? fromJson(String body) {
    final list = jsonDecode(body) as List<dynamic>;
    if (list.isEmpty) return null;
    final first = list.first as Map<String, dynamic>;
    final pkg =
        (first['binary'] as Map<String, dynamic>)['package']
            as Map<String, dynamic>;
    return AdoptiumRelease(
      version:
          (first['version'] as Map<String, dynamic>)['semver'] as String? ??
          first['release_name'] as String,
      url: Uri.parse(pkg['link'] as String),
      sha256: pkg['checksum'] as String,
      size: pkg['size'] as int,
      fileName: pkg['name'] as String,
    );
  }

  /// e.g. `21.0.12+1`.
  final String version;

  /// Download link.
  final Uri url;

  /// Expected SHA-256.
  final String sha256;

  /// Size in bytes.
  final int size;

  /// Archive file name.
  final String fileName;
}

/// Installs JDKs, cmdline-tools and SDK packages. Shared by `setup`,
/// `doctor --fix`, `jdk install` and `sdk install`.
class Installer {
  /// Creates an [Installer].
  Installer(this.ctx);

  /// Shared services.
  final DroidkitContext ctx;

  /// A resolver for [catalog] on [host].
  static PackageResolver resolver(SdkCatalog catalog, HostPlatform host) =>
      PackageResolver(catalog, host);

  Logger get _log => ctx.logger;

  /// Throws if [bytes] won't fit in [path]'s volume (with some headroom).
  Future<void> ensureDiskSpace(String path, int bytes, String what) async {
    final free = await freeBytes(path, ctx.host, ctx.runner);
    // Archives are extracted too, so need roughly 2.2x the download size.
    final needed = (bytes * 2.2).round();
    if (free != null && free < needed) {
      throw DroidkitException(
        'Not enough disk space for $what: need about ${formatBytes(needed)}, '
        'only ${formatBytes(free)} free at $path.',
        hint:
            'Free some space, or choose another location with --sdk-root '
            '(and DROIDKIT_HOME for droidkit\'s own files).',
        exitCode: ExitCode.ioError,
      );
    }
  }

  Future<void> _download(
    Uri url,
    String destination, {
    required String label,
    required String hash,
    required HashType hashType,
  }) async {
    final progress = Task(_log, 'Downloading $label');
    try {
      await ctx.downloader.download(
        url,
        destination,
        expectedHash: hash,
        hashType: hashType,
        onProgress: (received, total) {
          final pct = total == null || total == 0
              ? ''
              : ' ${(received * 100 / total).floor()}%';
          progress.update(
            'Downloading $label$pct (${formatBytes(received)}'
            '${total == null ? '' : ' / ${formatBytes(total)}'})',
          );
        },
      );
      progress.complete('Downloaded $label');
    } on Object {
      progress.fail('Download of $label failed');
      rethrow;
    }
  }

  Future<void> _extract(String archive, String dest, String label) async {
    final progress = Task(_log, 'Extracting $label');
    try {
      await const Extractor().extract(archive, dest);
      progress.complete('Extracted $label');
    } on Object catch (e) {
      progress.fail('Extracting $label failed');
      throw DroidkitException('Could not extract $archive: $e');
    }
  }

  /// Android API level that Flutter builds against when an app doesn't
  /// override `compileSdk` (read from the installed Flutter SDK).
  Future<int> flutterCompileSdk() async =>
      await ctx.flutter.defaultCompileSdk(
        (path) => File(path).readAsStringSync(),
      ) ??
      fallbackCompileSdk;

  // ---- JDK ----------------------------------------------------------------

  /// Asks Adoptium for the newest Temurin JDK [major] for this host.
  Future<AdoptiumRelease> findJdkRelease(int major) async {
    final host = ctx.host;
    if (host.arch == HostArch.other) {
      throw DroidkitException(
        'No Temurin JDK is published for ${host.description}.',
        hint:
            'Install a JDK $minJavaVersion–$maxJavaVersion yourself and set '
            'JAVA_HOME.',
      );
    }
    final os = host.isLinux && File('/etc/alpine-release').existsSync()
        ? 'alpine-linux'
        : host.os.adoptiumName;
    final url = Uri.https(
      'api.adoptium.net',
      '/v3/assets/latest/$major/hotspot',
      {'os': os, 'architecture': host.arch.adoptiumName, 'image_type': 'jdk'},
    );
    final release = AdoptiumRelease.fromJson(
      await ctx.downloader.getString(url),
    );
    if (release == null) {
      throw DroidkitException(
        'Adoptium has no JDK $major build for ${host.description}.',
      );
    }
    return release;
  }

  /// Downloads and installs Temurin [major] into droidkit's JDK folder.
  Future<Jdk> installJdk(int major) async {
    final release = await findJdkRelease(major);
    final dest = p.join(
      ctx.paths.jdkDir,
      'temurin-${release.version.replaceAll('+', '_')}',
    );
    final existing = await ctx.jdkLocator.inspect(
      ctx.jdkLocator.javaHomeIn(dest),
      'droidkit',
    );
    if (existing != null) {
      _log.info('Temurin ${release.version} is already installed.');
      return existing;
    }
    await ensureDiskSpace(ctx.paths.jdkDir, release.size, 'the JDK');
    final archive = p.join(ctx.paths.tmpDir, release.fileName);
    await _download(
      release.url,
      archive,
      label: 'Temurin JDK ${release.version}',
      hash: release.sha256,
      hashType: HashType.sha256,
    );
    try {
      await _extract(archive, dest, 'JDK');
    } finally {
      _deleteQuietly(archive);
    }
    final jdk = await ctx.jdkLocator.inspect(
      ctx.jdkLocator.javaHomeIn(dest),
      'droidkit',
    );
    if (jdk == null) {
      throw DroidkitException('The downloaded JDK at $dest does not run.');
    }
    ctx.config.jdkHome = jdk.home;
    ctx.saveConfig();
    ctx.jdkOverride = jdk;
    return jdk;
  }

  /// Returns a usable JDK, offering to install one if none is found.
  ///
  /// When [major] is set, only that feature release is accepted. Otherwise any
  /// supported JDK is reused, or Temurin [defaultJavaVersion] is downloaded.
  Future<Jdk> ensureJdk({int? major}) async {
    final found = await ctx.jdk();
    if (found != null && (major == null || found.majorVersion == major)) {
      return found;
    }

    final all = await ctx.jdkLocator.findAll(configured: ctx.config.jdkHome);
    for (final jdk in all) {
      if (!jdk.isSupported) {
        _log.warn('Ignoring Java at ${jdk.home}: it ${jdk.problem}.');
        continue;
      }
      if (major != null && jdk.majorVersion != major) {
        _log.warn(
          'Ignoring Java at ${jdk.home}: is Java ${jdk.majorVersion}, '
          'need $major.',
        );
        continue;
      }
      ctx.jdkOverride = jdk;
      return jdk;
    }

    final installMajor = major ?? defaultJavaVersion;
    _log.info(
      'Android\'s command-line tools need a JDK '
      '$minJavaVersion–$maxJavaVersion.',
    );
    final install = ctx.confirm(
      'Download Eclipse Temurin JDK $installMajor into ${ctx.paths.jdkDir}? '
      '(your system Java is not touched)',
    );
    if (!install) {
      throw DroidkitException(
        'A JDK is required.',
        hint:
            'Install JDK $defaultJavaVersion (e.g. from https://adoptium.net) '
            'and set JAVA_HOME, or run `droidkit jdk install`.',
        exitCode: ExitCode.unavailable,
      );
    }
    return installJdk(installMajor);
  }

  // ---- cmdline-tools --------------------------------------------------------

  /// Makes sure `cmdline-tools/latest` exists in [sdk], downloading it or
  /// moving a misplaced copy into place.
  ///
  /// [version] is a catalog version (`22.0`) or `latest`. With [replace], an
  /// existing `cmdline-tools/latest` is swapped for [version].
  Future<void> ensureCmdlineTools(
    AndroidSdk sdk, {
    String version = flutterCompatibleCmdlineTools,
    bool replace = false,
  }) async {
    if (sdk.hasCmdlineTools && !replace) return;
    if (!isWritable(sdk.root)) {
      throw DroidkitException(
        'Cannot write to ${sdk.root}.',
        hint:
            'Fix its permissions, or pick another location with '
            '--sdk-root.',
        exitCode: ExitCode.noPerm,
      );
    }
    final latest = p.join(sdk.root, 'cmdline-tools', 'latest');
    final misplaced = replace ? null : sdk.misplacedCmdlineTools;
    // A copy in cmdline-tools/<version>/ just needs renaming. (Legacy tools/
    // and a bare cmdline-tools/bin are left alone; a fresh copy is fetched.)
    if (misplaced != null &&
        p.basename(misplaced) != 'tools' &&
        misplaced != p.join(sdk.root, 'cmdline-tools')) {
      _log.info('Moving cmdline-tools from $misplaced to $latest');
      await Directory(misplaced).rename(latest);
      if (sdk.hasCmdlineTools) return;
    }

    final catalog = await ctx.catalogs.main();
    final resolved = PackageResolver(
      catalog,
      ctx.host,
    ).cmdlineTools(version: version);
    if (resolved == null) {
      throw DroidkitException(
        'Google publishes no command-line tools $version for '
        '${ctx.host.description}.',
      );
    }
    final (pkg, archive) = resolved;
    await ensureDiskSpace(sdk.root, archive.size, 'the command-line tools');
    final file = p.join(ctx.paths.tmpDir, p.basename(archive.url.path));
    await _download(
      archive.url,
      file,
      label: 'Android command-line tools ${pkg.revision}',
      hash: archive.sha1,
      hashType: HashType.sha1,
    );
    try {
      // Extractor replaces the destination atomically, so a failed download
      // or extraction never leaves the SDK without working tools.
      await _extract(file, latest, 'command-line tools');
    } finally {
      _deleteQuietly(file);
    }
    if (!sdk.hasCmdlineTools) {
      throw DroidkitException(
        'sdkmanager is missing after extracting ${archive.url}.',
      );
    }
  }

  // ---- licenses -------------------------------------------------------------

  /// Whether the licenses in [ids] are accepted in [sdk].
  ///
  /// Uses the acceptance files in `licenses/` — the same files Gradle checks
  /// before building — so it works with every cmdline-tools version.
  bool licensesAccepted(AndroidSdk sdk, {Set<String>? ids}) =>
      sdk.acceptedLicenseFiles().containsAll(ids ?? {defaultLicense});

  /// Gets the user's consent for the SDK licenses in [ids] and records it.
  ///
  /// Interactive users see the license text (from Google's catalog) and must
  /// agree. Non-interactive runs require `--yes`, mirroring
  /// `yes | sdkmanager --licenses`.
  Future<void> acceptLicenses(AndroidTools tools, {Set<String>? ids}) async {
    final required = ids ?? {defaultLicense};
    if (ctx.licensesConsented || licensesAccepted(tools.sdk, ids: required)) {
      _log.detail('Android SDK licenses already accepted');
      return;
    }
    if (!ctx.assumeYes) {
      if (!ctx.interactive) {
        throw DroidkitException(
          'The Android SDK licenses have not been accepted.',
          hint:
              'Review them with `droidkit licenses --show`, then re-run '
              'with --yes to accept.',
          exitCode: ExitCode.config,
        );
      }
      final catalog = await ctx.catalogs.main();
      final licenses = [for (final id in required) ?catalog.licenses[id]];
      _log.info(
        'Installing Android SDK packages requires accepting: '
        '${required.join(', ')}.',
      );
      if (_log.confirm('Show the full license text?')) {
        for (final license in licenses) {
          _log
            ..info(styleBold.wrap('── ${license.id} ──'))
            ..info(license.text.trim())
            ..info('');
        }
      }
      if (!_log.confirm('Do you accept these licenses?')) {
        throw DroidkitException(
          'The SDK licenses must be accepted to install Android packages.',
          exitCode: ExitCode.config,
        );
      }
    } else {
      _log.info(
        'Accepting the Android SDK licenses (--yes). Read them with '
        '`droidkit licenses --show`.',
      );
    }
    // Older cmdline-tools record acceptance here; 23+ records it during
    // package installation and ignores this call.
    final tail = <String>[];
    final code = await tools.licenses(
      acceptAll: true,
      onLine: (line) {
        _log.detail(line);
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        tail.add(trimmed);
        if (tail.length > 8) tail.removeAt(0);
      },
    );
    if (code != 0) {
      throw DroidkitException(
        'Recording license acceptance failed (exit $code).'
        '${tail.isEmpty ? '' : '\n${tail.join('\n')}'}',
        hint: 'Run again with --verbose for the full log.',
      );
    }
    ctx.licensesConsented = true;
  }

  /// Installs [packages] (skipping ones already present) with a progress line.
  Future<void> installPackages(
    AndroidTools tools,
    List<String> packages,
  ) async {
    final missing = packages
        .where((pkg) => !tools.sdk.isInstalled(pkg))
        .toList();
    for (final pkg in packages.where((pkg) => !missing.contains(pkg))) {
      _log.success('$pkg already installed');
    }
    if (missing.isEmpty) return;
    // sdkmanager is told to answer "y" to license prompts, so consent must
    // have been given first.
    await acceptLicenses(tools);

    final progress = Task(_log, 'Installing ${missing.join(', ')}');
    final tail = <String>[];
    final percent = RegExp(r'(\d+)%\s*(.*)');
    final code = await tools.install(
      missing,
      onLine: (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        tail.add(trimmed);
        if (tail.length > 30) tail.removeAt(0);
        final m = percent.firstMatch(trimmed);
        if (m != null) {
          progress.update(
            'Installing ${missing.join(', ')} — ${m.group(1)}% '
            '${m.group(2)}',
          );
        }
      },
    );
    final stillMissing = missing
        .where((pkg) => !tools.sdk.isInstalled(pkg))
        .toList();
    if (code != 0 || stillMissing.isNotEmpty) {
      progress.fail('Installing ${missing.join(', ')} failed');
      _log.detail(tail.join('\n'));
      throw DroidkitException(
        'sdkmanager could not install ${stillMissing.join(', ')}'
        ' (exit $code).\n${tail.reversed.take(8).toList().reversed.join('\n')}',
        hint: 'Run again with --verbose for the full log.',
      );
    }
    progress.complete('Installed ${missing.join(', ')}');
  }

  /// Removes droidkit's temp directory (leftovers from interrupted runs).
  void cleanTemp() {
    final dir = Directory(ctx.paths.tmpDir);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // In use by another droidkit process; leave it.
      }
    }
  }

  void _deleteQuietly(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}
