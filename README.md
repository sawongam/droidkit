# droidkit

[![pub package](https://img.shields.io/pub/v/droidkit.svg)](https://pub.dev/packages/droidkit)
![Publisher](https://img.shields.io/badge/Publisher-sawongam-blue.svg)

**The Android toolchain for Flutter, without Android Studio.**

droidkit is a cross-platform CLI (Linux, macOS, Windows) that installs and
manages the JDK, Android SDK, build tools, licenses, emulator and virtual
devices Flutter needs, wires them into Flutter and your shell, and repairs
broken setups.

```sh
dart pub global activate droidkit
droidkit setup
```

A few minutes later `flutter doctor` shows a green Android toolchain and
`droidkit start` boots an emulator.

| You need | Run |
| --- | --- |
| Everything installed, from scratch | `droidkit setup` |
| To find out what's broken, and fix it | `droidkit doctor --fix` |
| An emulator | `droidkit start` |
| Android SDK on CI | `droidkit --yes setup --no-emulator` |
| A JDK that won't touch your system Java | `droidkit jdk install` |
| `ANDROID_HOME` and `PATH` in your shell | `droidkit env --persist` |

## Why droidkit

Android Studio is a multi-gigabyte IDE. If you use VS Code, Zed, Neovim, a
headless server or CI, you only need the SDK and an emulator. Setting those up
by hand means the right cmdline-tools layout, a compatible JDK, licenses, a
system image for your CPU, an AVD and environment variables. droidkit does it
in one command, and it's written in Dart, so anyone with Flutter can run it.

## Features

- **One-command setup**: `droidkit setup`, or `droidkit --yes setup` unattended.
- **Reuses what you have**: finds existing SDKs and JDKs, installs only what's missing.
- **Always current**: reads Google's SDK catalog and the API level your Flutter builds against.
- **Verified downloads**: SHA-1 / SHA-256 checked, installed atomically.
- **`doctor --fix`**: checks SDK, JDK, licenses, KVM / Hypervisor / WHPX, WSL, Flutter config and disk space.
- **Emulators**: create, start (`--headless --wait` for CI), stop and delete.
- **JDK management**: Eclipse Temurin into `~/.droidkit/jdk`, system Java untouched.
- **Shell integration**: bash, zsh, fish, PowerShell and cmd.
- **CI-friendly**: non-interactive mode, exit codes, plain logs.

## Install

Requires the Dart SDK (bundled with Flutter).

```sh
dart pub global activate droidkit
```

Add `~/.pub-cache/bin` (Windows: `%LOCALAPPDATA%\Pub\Cache\bin`) to your `PATH`.

## Usage

```sh
droidkit setup          # JDK → SDK → licenses → platform/build-tools → emulator
droidkit start          # boot the emulator
flutter run

droidkit doctor --fix   # diagnose and repair an existing setup
```

| Command | What it does |
| --- | --- |
| `setup` | Install and configure the full toolchain. |
| `doctor [--fix]` | Diagnose (and repair) the toolchain. |
| `start [name]` / `stop [--all]` / `list` | Run and manage emulators. |
| `avd create \| delete \| devices` | Create and delete emulators. |
| `images [--api N]` | System images that run on this computer. |
| `sdk list \| install \| uninstall \| update` | Manage SDK packages. |
| `jdk install \| list` | Manage JDKs. |
| `licenses [--show]` | Review and accept Android SDK licenses. |
| `env [--persist]` | Shell environment (`eval "$(droidkit env)"`). |
| `clean [--all]` | Remove caches and what droidkit installed. |

Global options: `--sdk-root <path>`, `--yes`, `--verbose`. Run
`droidkit help <command>` for details. More in [example/](example/README.md).

## CI (GitHub Actions)

```yaml
- uses: subosito/flutter-action@v2
- run: dart pub global activate droidkit
- run: droidkit --yes setup --no-emulator
- run: flutter build apk
```

Emulator tests on Linux runners with KVM:

```sh
droidkit --yes avd create --image google_atd --name ci
droidkit start ci --headless --wait
flutter test integration_test
droidkit stop --all
```

`--yes` accepts the Android SDK licenses; read them first with `droidkit licenses --show`.

## Platform support

| Host | SDK & builds | Emulator |
| --- | --- | --- |
| Linux x64 | ✅ | ✅ (needs KVM) |
| macOS (Apple Silicon / Intel) | ✅ | ✅ |
| Windows x64 | ✅ | ✅ (needs WHPX or AEHD) |
| Linux arm64, Windows arm64 | ✅ | ❌ not published by Google |
| WSL 2 | ✅ | ❌ use the Windows side |

## Configuration

### `droidkit.toml`

Like `mise.toml`: if missing, `setup` writes one after installing; if present,
`setup` follows it and does not overwrite. CLI flags still win.

```toml
[tools]
jdk = "21"
cmdline-tools = "22.0"
platform = 36
build-tools = "37.0.0"

[emulator]
image = "google_apis_playstore"
name = "flutter_emu"
```

| Variable | Effect |
| --- | --- |
| `DROIDKIT_HOME` | droidkit's own files (default `~/.droidkit`). |
| `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` | Proxy for downloads. |
| `DROIDKIT_REPOSITORY_URL` | Alternative Google repository mirror. |
| `DROIDKIT_NO_UPDATE_CHECK` | Disable the daily update check. |

The SDK defaults to an existing install, else `~/Android/Sdk` (Linux),
`~/Library/Android/sdk` (macOS) or `%LOCALAPPDATA%\Android\Sdk` (Windows).
droidkit never changes your shell profile, Flutter config or system Java
without asking.

## Troubleshooting

- **"Android license status unknown" in `flutter doctor`**: command-line tools
  23+ confuse Flutter ≤ 3.47 ([flutter#191487](https://github.com/flutter/flutter/issues/191487)).
  droidkit installs 22.0 by default; `--cmdline-tools latest` opts in to 23.
- **Emulator slow or won't start on Linux**: run `droidkit doctor`; enable
  virtualization in BIOS and `sudo usermod -aG kvm $USER`. Logs are in `~/.droidkit/logs/`.
- **Windows hypervisor errors**: enable *Windows Hypervisor Platform* or install AEHD.
- **Behind a proxy**: set `HTTPS_PROXY`.

## Uninstall

```sh
droidkit clean --all
dart pub global deactivate droidkit
```

## Contributing

```sh
dart format . && dart analyze --fatal-infos && dart test
```

## License

MIT. droidkit is not affiliated with Google. Android SDK components are
downloaded from Google under their own licenses, which you accept via `droidkit licenses`.
