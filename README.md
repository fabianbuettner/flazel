# flazel

Nix pins your toolchain. Bazel builds your code. Nothing else required.

One `nix develop` and you have a hermetic compiler, linker, and libc. One `bazel build` and you have file-level incremental caching. Zero network calls after setup. Zero host dependencies beyond Nix. "Works on my machine" stops being a debugging statement and becomes a tautology: "my machine" is fully specified by a Nix derivation, which is the same everywhere.

## Features

### C/C++

- **GCC or Clang**, any version nixpkgs has. Pick your linker: mold, lld, gold, bfd.
- **Static** (musl), **dynamic** (glibc), or **bare metal** (no libc). Your choice, one parameter.
- **Cross-compilation**: x86_64, aarch64, riscv32, riscv64, mips64, arm. All in one shell.
- **Nixpkgs libraries**: `nixpkgsLibs = { openssl = pkgs.openssl; }` in Nix, `@openssl//:openssl` in Bazel. Transitive deps handled.
- **Hardened by default**: `_FORTIFY_SOURCE=3`, stack protectors, GLIBCXX assertions, split DWARF. Opt out per feature if you dare.
- **Sanitizers**: `asan`, `ubsan`, `tsan` as `--features=` flags. Mutual exclusion enforced. ASan+UBSan layering works.
- **Clang extras**: `layering_check`, `module_maps`, `parse_headers`. Find your missing `deps` before CI does.
- **Build tuning**: `thin_lto`, `gc_sections`, `hidden_visibility`, `gdb_index`
- **Coverage**: gcov and llvm-cov via `bazel coverage`

### Rust

- **Nix-provided rustc** threaded into Bazel (rules_rust downloads unpatched ELF binaries that segfault on NixOS. flazel uses rust-overlay's patchelf'd toolchain instead)
- **crate_universe**: Cargo deps resolved to Bazel targets. rules_rust's splice needs a host rustc that segfaults on NixOS; flazel overrides it with the Nix toolchain. Vendor the defs for fully offline builds (see [Offline Rust](#offline-rust))
- **Cross-compilation**: `aarch64-apple-ios`, `aarch64-unknown-linux-musl`, anything rustc supports
- **Dev shell**: rustc, cargo, clippy, rustfmt, nextest, cargo-llvm-cov, cargo-deny, bacon

### Shared

- **Offline builds**: BCR modules (and vendored crate archives) pre-fetched into the Nix store. After initial setup, the network is optional.
- **Non-BCR deps**: declared once in `flake.nix`, not duplicated in `MODULE.bazel`
- **Two lockfiles to bind them**: `flake.lock` pins nixpkgs, `MODULE.bazel.lock` pins Bazel deps. Together they fully determine every build input.

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
nix develop        # hermetic shell, everything declared above
bazel build //...  # incremental, cached
bazel test //...
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

      # Optional: for crate_universe users
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

Rust needs a CC toolchain for linking. On NixOS the system linker doesn't exist, so flazel provides both.

Wire the toolchains in `MODULE.bazel`:

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

# Required: the generated toolchain repo loads @rules_rust, but flazel has no
# rules_rust dep of its own (C++-only consumers must not inherit it). Hand the
# consumer's rules_rust to the extension.
inject_repo(nix_rust, "rules_rust")

# crate_universe needs a host rustc to splice Cargo metadata. rules_rust
# downloads one that segfaults on NixOS, so override it with the Nix toolchain.
host_tools = use_extension("@rules_rust//rust:extensions.bzl", "rust_host_tools")
host_tools.host_tools(edition = "2021", version = "1.85.0")

nix_rust_host_tools = use_repo_rule("@flazel//bazel:nix_rust.bzl", "nix_rust_host_tools")
nix_rust_host_tools(name = "nix_rust_host_tools")
override_repo(host_tools, rust_host_tools = "nix_rust_host_tools")

# Resolve Cargo deps into Bazel targets. from_cargo splices at build time and
# needs network; vendor the defs for offline builds (see Offline Rust below).
crate = use_extension("@rules_rust//crate_universe:extension.bzl", "crate")
crate.from_cargo(
    name = "crates",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
)
use_repo(crate, "crates")
```

Complete working example: [`tests/rust/`](tests/rust/).

## Offline Rust

`crate.from_cargo` re-splices every build and needs network access. For
air-gapped builds, vendor the crate definitions once and commit them.

Declare a `crates_vendor` target in `BUILD.bazel`:

```starlark
load("@rules_rust//crate_universe:defs.bzl", "crates_vendor")

crates_vendor(
    name = "crate_vendor",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
    mode = "remote",
    vendor_path = "3rdparty/crates",
    generate_build_scripts = True,
    tags = ["manual"],
)
```

Generate, and regenerate after a dependency bump, with:

```bash
nix develop -c bazel run //:crate_vendor
```

rules_rust calls the generated `crate_repositories()` from a WORKSPACE file.
flazel disables WORKSPACE, so wrap it in a module extension:

```starlark
# crates_vendor_extension.bzl
load("//3rdparty/crates:crates.bzl", "crate_repositories")

def _impl(_ctx):
    crate_repositories()

crates = module_extension(implementation = _impl)
```

```starlark
# MODULE.bazel (replaces the crate.from_cargo block above)
crates = use_extension("//:crates_vendor_extension.bzl", "crates")
use_repo(crates, "crate_vendor")
```

Reference crates through the hub repo: `@crate_vendor//:serde`. Only the hub is
imported, so a dependency bump plus a re-vendor updates the versioned spoke
repos automatically, with no hand-maintained list. The committed defs plus
crate archives from `mkBcrCaches` make the build fully offline. Working
example: [`tests/rust/`](tests/rust/).

## How it works

| Layer | Tool | Job |
|-------|------|-----|
| Environment | Nix | Provision toolchains, pin versions, guarantee hermeticity |
| Build | Bazel | Dependency graph, file-level caching, parallelism |

Nix produces deterministic store paths for compilers, linkers, libraries, and libc. Bazel consumes them as external repositories. Dev and CI use the same toolchain. No drift.

## Cross-compilation

Multiple toolchains in one shell:

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
    triple = "aarch64-unknown-linux-musl";   # cpu/os derive from the triple
    libc = pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic.stdenv.cc.libc;
    libcName = "musl";
    binutils = pkgs.pkgsCross.aarch64-multiplatform.buildPackages.binutils;
  };
};

shell = flazel.lib.cc.mkDevShell {
  inherit pkgs caches;
  toolchains = { default = hostCfg; aarch64 = aarch64Cfg; };
};
```

```bash
bazel build //...                                                # host
bazel build //... --platforms=@local_config_cc_aarch64//:platform # aarch64-musl
```

For Rust cross-targets that lack a real CC toolchain (e.g., iOS from a Linux host), declare a stub so Bazel's toolchain resolution doesn't complain:

```starlark
nix_cc.stub(name = "ios", target_cpu = "aarch64", target_os = "ios")
```

## Clang

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

Enables `layering_check`, `module_maps`, `parse_headers`, `template_diagnostics`.

## Toolchain features

Bazel `--features=` flags wired to compiler/linker options.

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
| `gdb_index` | `-Wl,--gdb-index` | needs gold, lld, or mold |
| `warnings` | `-Wall -Wextra` | |
| `warnings_pedantic` | adds `-Wpedantic -Wconversion` | |
| `treat_warnings_as_errors` | `-Werror` | |
| `asan` | `-fsanitize=address -fno-omit-frame-pointer` | `provides=["sanitizer"]` |
| `ubsan` | `-fsanitize=undefined` | layers with asan or tsan |
| `tsan` | `-fsanitize=thread` | `provides=["sanitizer"]` |
| `thin_lto` | `-flto=thin` / `-flto=auto` | |
| `hidden_visibility` | `-fvisibility=hidden` | |
| `freestanding` | `-ffreestanding` | usually set via `target.freestanding = true` |
| `template_diagnostics` | `-fdiagnostics-show-template-tree` | Clang only |

`freestanding` is the compile-side counterpart to bare metal's `-nostdlib` link
posture (`libc = null`): set `target.freestanding = true`. A no-libc build also
wants `--features=-stack_protector_strong` and no `-c opt` (its `fortify_source`),
since both emit calls to libc symbols a freestanding link cannot resolve.

### Usage

```bash
bazel build //... --features=warnings --features=treat_warnings_as_errors
bazel test //... --features=asan --features=ubsan
```

Or in `.bazelrc`:

```bazelrc
build:asan --features=asan --features=-tsan --compilation_mode=dbg
build:tsan --features=tsan --features=-asan --compilation_mode=dbg
```

Then `bazel test --config=asan //...` and done.

### Trap

`--features=asan,tsan` is **one** feature named `asan,tsan`. It doesn't match anything. Nothing happens. Silently. Repeat the flag:

```bash
--features=asan --features=ubsan      # correct
--features=asan,ubsan                 # silently ignored
```

Bazel cannot comma-split a repeatable list flag, so this is not fixable in flazel.
To stop repeating `--features`, bundle them once in a `--config` (see Usage above)
and type `--config=asan`.

## Non-BCR dependencies

### Bazel modules with no registry entry (`nonBcrDeps`)

For a `bazel_dep` whose module has no BCR entry, declare it in `flake.nix`:

```nix
nonBcrDeps = [
  {
    name = "my_module";
    url = "https://github.com/org/repo/archive/v1.0.tar.gz";
    hash = "sha256-...";
    stripPrefix = "repo-1.0";
  }
];
```

flazel fetches and extracts the archive and writes an `--override_module` flag to
`.bazelrc.nix`.

### Repositories and offline archives (`extraArchives`)

A non-module **repository** (anything declared in `MODULE.bazel` via
`use_repo_rule`: `http_archive`, `http_file`) is not a `nonBcrDeps` entry.
`--override_repository` cannot redirect it: a `use_repo_rule` repo's canonical
name is `_main~_repo_rules~<name>`, which the flag does not match. Declare the
repo in `MODULE.bazel` the normal way (with its `integrity`/`build_file`), and
make it resolve offline by seeding its archive into the repo cache, keyed by the
same sha256:

```nix
extraArchives = [
  { url = "https://github.com/org/data/archive/v1.tar.gz"; sha256 = "sha256-..."; }
];
```

`extraArchives` also covers archives the lock cannot express at all: globally
registered toolchains Bazel fetches via `download_and_extract` on a hardcoded URL
(e.g. aspect_bazel_lib's bats, the rules_python interpreter).

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
nix build  # same bits, every time
```

## Properties

**Hermetic.** If it builds, it builds everywhere. No implicit host deps.

**Reproducible.** Same inputs, same Nix store path. That's not a goal, it's a SHA-256 guarantee.

**Incremental.** Touch one `.cc` file, rebuild one target. Bazel tracks at file granularity.

**Offline.** Once the dev-shell closure is in your Nix store (first `nix develop`, an internal binary cache, or `nix copy` over sneakernet), the network is optional: `nix develop --offline` and Bazel builds both run air-gapped.

**Portable.** Install Nix. That's the entire prerequisites list.

## References

- [Nix Flakes](https://nixos.wiki/wiki/Flakes): reproducible package management
- [Bazel](https://bazel.build/): incremental build system
- [rules_cc](https://github.com/bazelbuild/rules_cc): Bazel rules for C/C++
- [rules_rust](https://github.com/bazelbuild/rules_rust): Bazel rules for Rust
- [rust-overlay](https://github.com/oxalica/rust-overlay): pinned Rust toolchains for Nix
