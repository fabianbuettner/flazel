# flazel-lock-archives, the dev shell's manifest generator; see archive_manifest.py.
{ pkgs }:
pkgs.writers.writePython3Bin "flazel-lock-archives" { } (builtins.readFile ./archive_manifest.py)
