# flazel

Hermetic Bazel builds powered by Nix. One command to set up your entire C/C++ toolchain — compilers, linkers, libraries, cross-compilers — with Bazel's incremental builds on top.

## Features

- **GCC and Clang** with configurable versions
- **Linker selection**: mold, lld, gold, bfd — integrated via Nix bintools override
- **Static linking** with musl, **dynamic linking** with glibc, **bare metal** with no libc
- **Cross-compilation**: x86_64, aarch64, riscv64, mips64, arm — multiple toolchains in one shell
- **Nixpkgs library integration**: declare `nixpkgsLibs = { openssl = pkgs.openssl; }` and use `@openssl//:openssl` in Bazel
- **Clang dependency checking**: `layering_check` ensures every `#include` comes from a direct `deps` target; `parse_headers` validates headers compile standalone
- **Code coverage**: gcov and llvm-cov with Bazel coverage integration
- **Non-BCR dependency management**: archive_override and http_archive deps managed from flake.nix, deduplicated via `--override_module` / `--override_repository`
- **Offline hermetic builds**: BCR modules and registry metadata pre-fetched into Nix store
- **C/C++ standard control**: configurable per toolchain (default: C17, C++23)

## Quick Start

```nix
# flake.nix
{
  inputs.flazel.url = "github:fabianbuettner/flazel";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, flazel, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      cfg = flazel.lib.cc.mkConfig {
        inherit pkgs;
        gcc = pkgs.gcc15;
        linker = "mold";
        nixpkgsLibs = {
          openssl = pkgs.openssl;
          zlib = pkgs.zlib;
        };
      };

      caches = flazel.lib.mkBcrCaches {
        inherit pkgs;
        lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
      };
    in {
      devShells.x86_64-linux.default = flazel.lib.cc.mkDevShell {
        inherit pkgs caches;
        toolchains = { default = cfg; };
      };
    };
}
```

```bash
nix develop        # Enter hermetic shell with GCC 15 + mold
bazel build //...  # Incremental build
bazel test //...   # Run tests
```

## How It Works

flazel assigns each tool to its strength:

| Layer | Tool | Responsibility |
|-------|------|----------------|
| Environment | Nix | Toolchain provisioning, dependency pinning, hermeticity |
| Compilation | Bazel | Dependency graph, incremental builds, caching |

Nix provides pinned compilers, linkers, libraries, and libc as reproducible derivations. Bazel provides file-level dependency tracking and parallel incremental builds. Both `nix develop` and `nix build` use identical toolchains — no environment drift between development and CI.

## Cross-Compilation

Multiple toolchains coexist in a single dev shell:

```nix
hostCfg = flazel.lib.cc.mkConfig {
  inherit pkgs;
  gcc = pkgs.gcc15;
  linker = "mold";
};

aarch64Cfg = flazel.lib.cc.mkConfig {
  inherit pkgs;
  toolchainName = "aarch64";
  static = true;
  gcc = pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic.buildPackages.gcc15;
  target = {
    triple = "aarch64-unknown-linux-musl";
    cpu = "aarch64";
    os = "linux";
    libc = pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic.stdenv.cc.libc;
    libcName = "musl";
    binutils = pkgs.pkgsCross.aarch64-multiplatform.buildPackages.binutils;
  };
};

shell = flazel.lib.cc.mkDevShell {
  inherit pkgs caches;
  toolchains = {
    default = hostCfg;
    aarch64 = aarch64Cfg;
  };
};
```

```bash
bazel build //...                                          # Build for host
bazel build //... --platforms=@local_config_cc_aarch64//:platform  # Cross-compile
```

Libraries declared via `nixpkgsLibs` are automatically available for all toolchains with platform-aware selection.

## Clang Toolchain

```nix
clangCfg = flazel.lib.cc.mkConfig {
  inherit pkgs;
  toolchainName = "clang";
  compiler = "clang";
  clang = pkgs.clang_19;
  linker = "mold";
  llvmBintools = pkgs.llvmPackages_19.bintools-unwrapped;
  nixpkgsLibs = { ... };
};
```

Enables `layering_check`, `module_maps`, and `parse_headers` features in Bazel.

## Non-BCR Dependencies

Dependencies not in the Bazel Central Registry are declared once in `flake.nix`:

```nix
nonBcrDeps = [
  {
    name = "my_module";
    type = "module";  # generates --override_module
    url = "https://github.com/org/repo/archive/v1.0.tar.gz";
    hash = "sha256-...";
    stripPrefix = "repo-1.0";
  }
  {
    name = "my_data";
    type = "repo";  # generates --override_repository
    url = "https://github.com/org/data/archive/v2.0.tar.gz";
    hash = "sha256-...";
    stripPrefix = "data-2.0";
    buildFile = ./bazel/my_data.BUILD;
  }
];
```

flazel fetches, extracts, and generates `--override_module` / `--override_repository` flags in `.bazelrc.nix`. No `archive_override` in MODULE.bazel needed — no duplication.

## Reproducible Releases

```nix
release = flazel.lib.cc.mkDerivation {
  inherit pkgs caches;
  name = "my-project";
  src = ./.;
  cfg = staticCfg;
  bazelCommand = "build //...";
  installPhase = "cp -rL bazel-bin/app $out/bin/app";
};
```

```bash
nix build  # Identical output every time
```

## Properties

**Hermetic** — Builds depend only on declared inputs. No implicit system dependencies.

**Reproducible** — `flake.lock` pins nixpkgs; `MODULE.bazel.lock` pins Bazel deps. Identical inputs produce identical outputs.

**Incremental** — Bazel tracks dependencies at file granularity. Changing one file rebuilds only affected targets.

**Offline** — BCR modules are pre-fetched into the Nix store. After initial setup, builds require no network access.

**Portable** — The only host requirement is a Nix installation.

## References

- [Nix Flakes](https://nixos.wiki/wiki/Flakes) — Hermetic, reproducible package management
- [Bazel](https://bazel.build/) — Scalable, incremental build system
