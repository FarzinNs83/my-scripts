# fgen

Feature generator for Flutter: Clean / MVVM / Simple architecture with
Riverpod / Bloc / Cubit / Provider / GetX. Also sets up a new project, adds
routed screens, turns JSON into model classes and writes asset constants.
Requires Python 3.9+.

## Install
Go to flutter-fgen folder and use the command below:
```bash
pip install .
```

Or without installing: add `flutter-fgen/bin` to your `PATH`.

## Usage

Run inside a Flutter project:

```bash
fgen init                            # set up a fresh project (asks for arch / state)
fgen auth                            # a feature (uses the 'fgen init' choices)
fgen page settings                   # a screen, registered in the router
fgen widget primary_button           # lib/core/widgets/primary_button.dart
fgen model User --file user.json     # model classes from a JSON sample
fgen assets                          # constants for assets/ + pubspec entries
fgen --help                          # all options; 'fgen <command> --help' for one command
```

## fgen init

Run it once, right after `flutter create`:

```bash
fgen init                            # interactive
fgen init -s bloc -r either --pub    # no questions; add the packages too
fgen init --no-router                # no go_router / GetX pages
```

It writes:

| Path | What |
| --- | --- |
| `lib/core/network/` | `createDio()` with auth, retry and debug log interceptors; `ApiException.fromDio()` |
| `lib/core/config/env.dart` + `env/*.json` | flavor and `BASE_URL` from `--dart-define-from-file` |
| `lib/core/theme/` | `AppColors`, `AppTextStyles`, `AppTheme.light` / `.dark` |
| `lib/core/router/` | go_router (`AppRoutes`, `appRouter`), or GetX pages when the state is GetX |
| `lib/core/di/` | get_it / GetX binding / Riverpod provider for Dio, depending on the state |
| `lib/app.dart`, `lib/main.dart` | app shell wired to the theme, router and DI |
| `lib/features/home/` | a home screen at `/` |

`lib/main.dart` and `test/widget_test.dart` are only replaced while they still
hold the `flutter create` counter app (or with `--force`). Your choices are
saved to `.fgen/config.json`, so later `fgen <feature>` runs use the same
architecture and state management without flags.

Run the app with:

```bash
flutter run --dart-define-from-file=env/dev.json
```

## Features

```bash
fgen auth,profile -a mvvm -s bloc    # two features, MVVM + Bloc
fgen cart -r either -m plain         # Either<Failure, T>, no freezed
fgen cart --only domain,data         # only some layers
fgen cart --dry-run                  # preview only
fgen list                            # architectures, state managers, layers
```

After `fgen init`, a new feature's screen is added to the router, and with
Bloc / Cubit / Provider its `initXFeature()` call is added to `main()`. Use
`--no-route` to skip the routing.

## fgen page / fgen widget

```bash
fgen page settings                   # lib/features/settings/presentation/screens/settings_screen.dart, route /settings
fgen page login --in auth --stateful # a second screen inside the auth feature
fgen page product --path product/:id # custom path (Git Bash: no leading slash)
fgen widget avatar --in profile      # lib/features/profile/presentation/widgets/avatar.dart
```

Screens are `ConsumerWidget`s when the project uses Riverpod. Routes are
inserted above the `// fgen:routes` / `// fgen:imports` markers that
`fgen init` puts in the router files; keep the markers if you edit them.

## fgen model

```bash
fgen model User --file user.json                    # lib/core/models/user.dart
fgen model Product --in shop -m plain               # paste the JSON, into the shop feature's models folder
curl -s https://api.example.com/users/1 | fgen model User
fgen model User --file user.json --nullable -n      # every field nullable; print only
```

Nested objects become their own classes, arrays of objects are merged (keys
missing from some items become nullable), `snake_case` keys become camelCase
fields, and `null` values become nullable. `-m freezed` writes freezed +
json_serializable classes, `-m plain` writes `fromJson` / `toJson` /
`copyWith` by hand. The default is the project's choice from `fgen init`.

## fgen assets

```bash
fgen assets                          # scan assets/, write lib/core/constants/app_assets.dart
fgen assets --no-pubspec -n          # preview, leave pubspec.yaml alone
```

Each top-level folder gets a class (`assets/images/logo.png` becomes
`AppImages.logo`, `assets/icons/social/google.svg` becomes
`AppIcons.socialGoogle`). Every folder that holds files is added to
`flutter: assets:` in `pubspec.yaml`. Fonts, hidden files and `2.0x` / `3.0x`
variants are skipped. Run it again after adding or removing files.

## Custom templates

```bash
fgen eject                           # copy the templates to .fgen/templates
```

Edit the copies you want to change and delete the rest; fgen prefers them
over the built-in ones.
