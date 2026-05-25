# flazel

Your compiler, your linker, your libc. Pinned by hash, sandboxed by Nix, cached by Bazel.

`nix develop` gives you a hermetic toolchain. `bazel build` gives you file-level incrementality. Nothing is downloaded at build time. Nothing depends on what's installed on the host. The only prerequisite is Nix itself.

The same toolchain runs on every developer machine and in CI. "Works on my machine" becomes a tautology.

## What you get

### C/C++

- **GCC or Clang**, any version nixpkgs carries
- **Linker selection**: mold, lld, gold, bfd (integrated via Nix bintools override, not `-B` hacks)
- **Static linking** with musl, **dynamic linking** with glibc, **bare metal** with no libc
- **Cross-compilation**: x86_64, aarch64, riscv64, mips64, arm. Multiple toolchains in one shell.
- **Nixpkgs libraries**: declare `nixpkgsLibs = { openssl = pkgs.openssl; }`, use `@openssl//:openssl` in Bazel. Transitive deps resolved automatically.
- **Clang dependency checking**: `layering_check` ensures every `#include` comes from a direct `deps` target. `parse_headers` validates headers compile standalone.
- **Hardened by default**: `_GLIBCXX_ASSERTIONS`, `_FORTIFY_SOURCE=3`, `-fstack-protector-strong`, split DWARF, sandbox-safe debug prefix maps. All on. Opt out per feature.
- **Sanitizers**: `asan`, `ubsan`, `tsan` as Bazel features with mutual exclusion via `provides=["sanitizer"]`
- **Build tuning**: `thin_lto`, `gc_sections`, `hidden_visibility`, `gdb_index`
- **Coverage**: gcov and llvm-cov, integrated with `bazel coverage`
- **Standard control**: configurable per toolchain (default: C17, C++23)

### Rust

- **Nix-provided rustc** wired into Bazel (NixOS cannot run downloaded rustc binaries; flazel builds the toolchain from `rust-overlay` and threads it through)
- **Configurable version** and target triples
- **Cross-compilation**: `aarch64-apple-ios`, `aarch64-unknown-linux-musl`, anything rustc supports
- **crate_universe**: Nix-built `cargo-bazel` so Cargo dependency resolution works on NixOS
- **Dev shell**: rustc, cargo, clippy, rustfmt, nextest, cargo-llvm-cov, cargo-deny, bacon
- **Coverage**: `bazel coverage` with llvm-cov instrumentation

### Both languages

- **Offline hermetic builds**: BCR modules and registry metadata pre-fetched into the Nix store. After `nix develop`, zero network calls.
- **Non-BCR deps**: `archive_override` and `http_archive` dependencies declared in `flake.nix`, not duplicated in `MODULE.bazel`.
- **One source of truth**: `flake.lock` pins nixpkgs. `MODULE.bazel.lock` pins Bazel deps. `flake.nix` pins everything else.

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
nix develop        # Hermetic shell with everything declared above
bazel build //...  # Incremental build, cached
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

Rust on NixOS needs a CC toolchain too (for linking). flazel provides both from Nix, so the linker binary actually runs.

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
nix develop        # rustc 1.85.0 + cargo + clippy + cargo-bazel, hermetic
bazel build //...  # Build with Nix-provided rustc
bazel test //...   # Run tests
```

A complete working example is in [`tests/rust/`](tests/rust/).

## How it works

Each tool does what it's best at:

| Layer | Tool | Job |
|-------|------|-----|
| Environment | Nix | Provision toolchains, pin versions, guarantee hermeticity |
| Build | Bazel | Track the dependency graph, cache at file granularity, parallelize |

Nix produces reproducible store paths for compilers, linkers, libraries, and libc. Bazel consumes them as external repositories. `nix develop` and `nix build` use identical toolchains. No drift between dev and CI.

## Cross-compilation

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
bazel build //...                                                # Host
bazel build //... --platforms=@local_config_cc_aarch64//:platform # aarch64-musl
```

Libraries declared via `nixpkgsLibs` are available for all toolchains with platform-aware `select()`.

For Rust cross-targets that lack a real CC toolchain (e.g., iOS from a Linux host), declare a stub:

```starlark
nix_cc.stub(name = "ios", target_cpu = "aarch64", target_os = "ios")
```

This satisfies Bazel's toolchain resolution without providing an actual compiler.

## Clang toolchain

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

Unlocks Clang-only features: `layering_check`, `module_maps`, `parse_headers`, `template_diagnostics`. See [Toolchain features](#toolchain-features).

## Toolchain features

Bazel `--features=` flags wired to compiler/linker options. Defaults harden every build. Opt-in features layer per-target or per-config.

### Default-on (opt out with `--features=-name`)

| Feature | Flags | When |
|---|---|---|
| `glibcxx_assertions` | `-D_GLIBCXX_ASSERTIONS` | always |
| `fortify_source` | `-D_FORTIFY_SOURCE=3` | always |
| `stack_protector_strong` | `-fstack-protector-strong` | always |
| `colored_diagnostics` | `-fdiagnostics-color=always` | always |
| `debug_prefix_map` | `-ffile-prefix-map=/proc/self/cwd=.` | always |
| `frame_pointer` | `-fno-omit-frame-pointer` | `-c dbg` |
| `split_debug` | `-gsplit-dwarf` | `-c dbg` |
| `gc_sections` | `-ffunction-sections -fdata-sections -Wl,--gc-sections` | `-c opt` |

### Opt-in

| Feature | Flags | Notes |
|---|---|---|
| `gdb_index` | `-Wl,--gdb-index` | `-c dbg`; needs gold, lld, or mold |
| `warnings` | `-Wall -Wextra` | |
| `warnings_pedantic` | adds `-Wpedantic -Wconversion` | |
| `treat_warnings_as_errors` | `-Werror` | |
| `asan` | `-fsanitize=address -fno-omit-frame-pointer` | `provides=["sanitizer"]` |
| `ubsan` | `-fsanitize=undefined -fno-sanitize-recover=undefined` | layers with asan or tsan |
| `tsan` | `-fsanitize=thread` | `provides=["sanitizer"]` |
| `thin_lto` | `-flto=thin` (Clang) / `-flto=auto` (GCC) | |
| `hidden_visibility` | `-fvisibility=hidden -fvisibility-inlines-hidden` | |
| `template_diagnostics` | `-fdiagnostics-show-template-tree` | Clang only |

### Usage

```bash
# Wall + Werror
bazel build //... --features=warnings --features=treat_warnings_as_errors

# AddressSanitizer
bazel test //... --features=asan

# ASan + UBSan (the canonical LLVM CI combo)
bazel test //... --features=asan --features=ubsan
```

Per-config profiles in `.bazelrc`:

```bazelrc
build:asan --features=asan
build:asan --features=-tsan
build:asan --compilation_mode=dbg

build:tsan --features=tsan
build:tsan --features=-asan
build:tsan --compilation_mode=dbg
```

Then `bazel test --config=asan //...` flips the entire project into sanitizer mode.

### Trap

`--features=asan,tsan` is **not** two features. Bazel parses it as one feature literally named `asan,tsan`. It doesn't exist, so nothing happens. Silently. Always repeat the flag:

```bash
--features=asan --features=ubsan      # correct
--features=asan,ubsan                 # silently ignored
```

## Non-BCR dependencies

Dependencies outside the Bazel Central Registry are declared once in `flake.nix`:

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

flazel fetches, extracts, and writes `--override_module` / `--override_repository` flags to `.bazelrc.nix`. No `archive_override` in MODULE.bazel. No duplication.

## Reproducible releases

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
nix build  # bit-for-bit identical output, every time
```

## Properties

**Hermetic.** Builds depend only on declared inputs. No implicit host dependencies. If it builds on your machine, it builds on every machine.

**Reproducible.** `flake.lock` pins nixpkgs. `MODULE.bazel.lock` pins Bazel deps. Same inputs, same outputs. The Nix store path is the proof.

**Incremental.** Bazel tracks dependencies at file granularity. Touch one file, rebuild one target. Remote caching works out of the box.

**Offline.** BCR modules are pre-fetched into the Nix store. After `nix develop`, builds need zero network access. Air-gapped CI is possible.

**Portable.** The only host requirement is a Nix installation. Everything else comes from the Nix store.

## References

- [Nix Flakes](https://nixos.wiki/wiki/Flakes): reproducible, hermetic package management
- [Bazel](https://bazel.build/): scalable, incremental build system
- [rules_rust](https://github.com/bazelbuild/rules_rust): Bazel rules for Rust
- [rust-overlay](https://github.com/oxalica/rust-overlay): Nix overlay for pinned Rust toolchains
