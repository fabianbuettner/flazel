# flazel

Hermetic Bazel builds powered by Nix. One command to set up your entire toolchain — C/C++ or Rust — with Bazel's incremental builds on top.

## Features

### C/C++

- **GCC and Clang** with configurable versions
- **Linker selection**: mold, lld, gold, bfd — integrated via Nix bintools override
- **Static linking** with musl, **dynamic linking** with glibc, **bare metal** with no libc
- **Cross-compilation**: x86_64, aarch64, riscv64, mips64, arm — multiple toolchains in one shell
- **Nixpkgs library integration**: declare `nixpkgsLibs = { openssl = pkgs.openssl; }` and use `@openssl//:openssl` in Bazel
- **Clang dependency checking**: `layering_check` ensures every `#include` comes from a direct `deps` target; `parse_headers` validates headers compile standalone
- **Hardened by default**: `_GLIBCXX_ASSERTIONS`, `_FORTIFY_SOURCE=3`, `-fstack-protector-strong`, split DWARF, sandbox-safe debug paths — all on, opt out per feature
- **Warnings**: `warnings` (`-Wall -Wextra`), `warnings_pedantic`, `treat_warnings_as_errors` — opt-in, one knob per noise level
- **Sanitizers**: `asan`, `ubsan`, `tsan` as Bazel features. Mutual exclusion enforced via `provides=["sanitizer"]`; `asan + ubsan` layering supported
- **Build-time tuning**: `thin_lto`, `gc_sections` (auto-on for `-c opt`), `hidden_visibility` — opt-in performance features
- **Code coverage**: gcov and llvm-cov with Bazel coverage integration
- **C/C++ standard control**: configurable per toolchain (default: C17, C++23)

### Rust

- **Nix-provided rustc** wired into Bazel via custom toolchain (NixOS cannot run downloaded rustc binaries)
- **Configurable Rust version** and target triples
- **Cross-compilation**: `aarch64-apple-ios`, `aarch64-unknown-linux-musl`, and any target rustc supports
- **crate_universe** integration: Nix-built `cargo-bazel` for Cargo-to-Bazel dependency resolution
- **Dev shell**: rustc, cargo, clippy, rustfmt, nextest, cargo-llvm-cov, cargo-deny, bacon
- **Bazel rules**: `rust_library`, `rust_binary`, `rust_test`, `rust_clippy`, `rustfmt_test`
- **Coverage**: `bazel coverage` with llvm-cov instrumentation

### Shared

- **Offline hermetic builds**: BCR modules and registry metadata pre-fetched into Nix store
- **Non-BCR dependency management**: archive_override and http_archive deps managed from flake.nix

## Quick Start (C/C++)

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

## Quick Start (Rust)

```nix
# flake.nix
{
  inputs.flazel.url = "github:fabianbuettner/flazel";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.rust-overlay.url = "github:oxalica/rust-overlay";

  outputs = { self, nixpkgs, flazel, rust-overlay, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ rust-overlay.overlays.default ];
      };

      ccCfg = flazel.lib.cc.mkConfig { inherit pkgs; };

      rustCfg = flazel.lib.rust.mkConfig {
        inherit pkgs;
        rustVersion = "1.85.0";
        targets = [
          "x86_64-unknown-linux-gnu"
          "aarch64-apple-ios"
          "aarch64-unknown-linux-musl"
        ];
      };

      caches = flazel.lib.mkBcrCaches {
        inherit pkgs;
        lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
      };
      # Optional: for projects using crate_universe (Cargo deps in Bazel)
      cargoBazel = flazel.lib.rust.mkCargoBazel { inherit pkgs; };
    in {
      devShells.x86_64-linux.default = flazel.lib.rust.mkDevShell {
        inherit pkgs caches cargoBazel;
        flazelPath = flazel.outPath;
        toolchains = { default = rustCfg; };
        ccToolchains = { default = ccCfg; };
      };
    };
}
```

The CC toolchain is required alongside Rust — Rust needs a linker, and on NixOS it must come from Nix.

The consumer's `MODULE.bazel` wires the Nix-provided toolchains into Bazel:

```starlark
bazel_dep(name = "rules_rust", version = "0.56.0")
bazel_dep(name = "rules_cc", version = "0.1.4")
bazel_dep(name = "flazel", version = "0.0.1")

nix_cc = use_extension("@flazel//bazel:nix_cc.bzl", "nix_cc")
nix_cc.toolchain(name = "default")
use_repo(nix_cc, "local_config_cc_default", "local_config_cc_default_deps")

nix_rust = use_extension("@flazel//bazel:nix_rust.bzl", "nix_rust")
nix_rust.toolchain(name = "default")
use_repo(nix_rust, "local_config_rust_default")
register_toolchains("@local_config_rust_default//:all")

host_tools = use_extension("@rules_rust//rust:extensions.bzl", "rust_host_tools")
host_tools.host_tools(edition = "2021", version = "1.85.0")

# Optional: Cargo dependencies via crate_universe
crate = use_extension("@rules_rust//crate_universe:extension.bzl", "crate")
crate.from_cargo(
    name = "crates",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
)
use_repo(crate, "crates")
```

```bash
nix develop        # Enter hermetic shell with rustc 1.85.0, cargo, clippy, ...
bazel build //...  # Build with Nix-provided rustc
bazel test //...   # Run tests
```

A complete working example is in [`tests/rust/`](tests/rust/).

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

Adds Clang-only features: `layering_check`, `module_maps`, `parse_headers`, `template_diagnostics`. See [Toolchain Features](#toolchain-features) for the full list.

## Toolchain Features

Compile-time and runtime feature flags wired through Bazel's `--features=` mechanism. Default-on features harden every build. Opt-in features layer per-target, per-config, or per-build.

### Default-on (opt out with `--features=-name`)

| Feature | Flags | Mode |
|---|---|---|
| `glibcxx_assertions` | `-D_GLIBCXX_ASSERTIONS` | always |
| `fortify_source` | `-D_FORTIFY_SOURCE=3` | always |
| `stack_protector_strong` | `-fstack-protector-strong` | always |
| `colored_diagnostics` | `-fdiagnostics-color=always` | always |
| `debug_prefix_map` | `-ffile-prefix-map=/proc/self/cwd=.` | always |
| `frame_pointer` | `-fno-omit-frame-pointer` | `-c dbg` |
| `split_debug` | `-gsplit-dwarf` (compile) | `-c dbg` |
| `gc_sections` | `-ffunction-sections -fdata-sections -Wl,--gc-sections` | `-c opt` |

### Opt-in

| Feature | Flags | Notes |
|---|---|---|
| `gdb_index` | `-Wl,--gdb-index` (link) | `-c dbg`; requires gold/lld/mold (not bfd) |
| `warnings` | `-Wall -Wextra` | |
| `warnings_pedantic` | adds `-Wpedantic -Wconversion` | requires `warnings` |
| `treat_warnings_as_errors` | `-Werror` | pairs with `warnings` |
| `asan` | `-fsanitize=address -fno-omit-frame-pointer` (compile + link) | `provides=["sanitizer"]` |
| `ubsan` | `-fsanitize=undefined -fno-sanitize-recover=undefined` | layers with asan or tsan |
| `tsan` | `-fsanitize=thread` (compile + link) | `provides=["sanitizer"]` |
| `thin_lto` | `-flto=thin` (Clang) / `-flto=auto` (GCC) | linker must support LTO |
| `hidden_visibility` | `-fvisibility=hidden -fvisibility-inlines-hidden` | |
| `template_diagnostics` | `-fdiagnostics-show-template-tree -ftemplate-backtrace-limit=0` | Clang only |

### Usage

```bash
# Strict warning regime
bazel build //... --features=warnings --features=treat_warnings_as_errors

# Run tests under AddressSanitizer
bazel test //... --features=asan

# Layer ubsan on top of asan (the canonical LLVM CI configuration)
bazel test //... --features=asan --features=ubsan
```

The natural fit is per-config profiles in `.bazelrc`:

```bazelrc
build:asan --features=asan
build:asan --features=-tsan
build:asan --compilation_mode=dbg

build:tsan --features=tsan
build:tsan --features=-asan
build:tsan --compilation_mode=dbg
```

Then `bazel test --config=asan //...` flips the whole project under sanitizer in one flag.

### One trap to know about

Bazel's `--features=` flag takes **one** feature per occurrence. The form `--features=asan,tsan` is parsed as a single feature literally named `asan,tsan` — which doesn't exist, so the build silently runs without sanitizers. Always repeat the flag:

```bash
--features=asan --features=ubsan      # ✅ both enabled
--features=asan,ubsan                 # ❌ silently neither
```

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
- [rules_rust](https://github.com/bazelbuild/rules_rust) — Bazel rules for Rust
- [rust-overlay](https://github.com/oxalica/rust-overlay) — Nix overlay for Rust toolchains
