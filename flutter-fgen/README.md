# fgen

Feature generator for Flutter: Clean / MVVM / Simple architecture with
Riverpod / Bloc / Cubit / Provider / GetX. Requires Python 3.9+.

## Install
Go to flutter-fgen folder and use the command below:
```bash
pip install .
```

Or without installing: add `flutter-fgen/bin` to your `PATH`.

## Usage

Run inside a Flutter project:

```bash
fgen                                 # interactive mode
fgen auth                            # clean + riverpod (defaults)
fgen auth,profile -a mvvm -s bloc    # two features, MVVM + Bloc
fgen cart --dry-run                  # preview only
fgen list                            # architectures, state managers, layers
fgen --help                          # all options
```
