# droidkit examples

## First-time setup on a new machine

```sh
dart pub global activate droidkit
droidkit setup          # guided: JDK, SDK, licenses, emulator, Flutter config
droidkit start          # boot your emulator
flutter run
```

## Lock versions in the project (`droidkit.toml`)

```toml
[tools]
jdk = "21"
cmdline-tools = "22.0"
platform = "36"
build-tools = "37.0.0"

[emulator]
image = "google_apis_playstore"
name = "flutter_emu"
```

```sh
droidkit --yes setup    # reads droidkit.toml from this directory or a parent
```

## Reuse an SDK you already have

`droidkit setup` detects `ANDROID_HOME`, `flutter config --android-sdk` and the
default Android Studio location, and only installs what's missing:

```sh
droidkit doctor         # see what's wrong
droidkit doctor --fix   # repair it
```

## Put the SDK on another disk

```sh
droidkit --sdk-root /mnt/big-disk/android setup
```

## CI (GitHub Actions, GitLab, …)

```sh
dart pub global activate droidkit
droidkit --yes setup --no-emulator          # SDK only; --yes accepts licenses
eval "$(droidkit env)"                       # ANDROID_HOME + PATH in this shell step
flutter build apk
```

Integration tests on an emulator (Linux runners with KVM):

```sh
droidkit --yes avd create --image google_atd --name ci
droidkit start ci --headless --wait
flutter test integration_test
droidkit stop --all
```

## Emulators

```sh
droidkit images --api 36                       # what can run on this computer
droidkit avd create --api 35 --image google_apis --device pixel_7
droidkit list                                  # ● = running
droidkit start Pixel_7_API_35 --cold
droidkit start -- -dns-server 8.8.8.8          # extra emulator flags after --
droidkit stop --all
```

## Java

```sh
droidkit jdk list                # every JDK droidkit can find, and which it uses
droidkit jdk install --version 21
```

## Shell environment

```sh
eval "$(droidkit env)"           # bash/zsh, current shell only
droidkit env --shell fish | source
droidkit env --persist           # add to ~/.zshrc / ~/.bashrc / fish conf.d
droidkit env --unpersist         # remove it again
```
