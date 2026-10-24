# flazel

Nix pins your toolchain. Bazel builds your code. Nothing else required.

One `nix develop` and you have a hermetic compiler, linker, and libc. One `bazel build` and you have file-level incremental caching. Zero network calls after setup. Zero host dependencies beyond Nix. "Works on my machine" stops being a debugging statement and becomes a tautology: "my machine" is fully specified by a Nix derivation, which is the same everywhere.

## Features

### C/C++

- **GCC or Clang**, any version nixpkgs has. Pick your linker: mold, lld, gold, bfd.
- **Static** (musl), **dynamic** (glibc), or **bare metal** (no libc). Your choice, one parameter.
- **Cross-compilation**: x86_64, aarch64, riscv32, riscv64, mips64, arm, and 32- and 64-bit Windows (mingw-w64). All in one shell.
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
- **Two lockfiles to bind them**: `flake.lock` pins nixpkgs, `MODULE.bazel.lock` pins Bazel deps. Together they fully determine every build input. Downloads that Bazel hides from the lockfile (reproducible module extensions, e.g. rules_rust's internal crates) can be enumerated in a committed `flazel-archives.json` for strict-offline builds, regenerated with `flazel-lock-archives` (see [Offline Rust](#offline-rust)).

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

      # Optional: for crate_universe users. Version + source derive from the
      # lockfile's resolved rules_rust, so the generator cannot skew from the
      # bazel_dep the build uses.
      cargoBazel = flazel.lib.rust.mkCargoBazel {
        inherit pkgs;
        lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
      };
    in {
      devShells.x86_64-linux.default = flazel.lib.rust.mkDevShell {
        inherit pkgs caches cargoBazel;
        toolchains = { default = rustCfg; };
        ccToolchains = { default = ccCfg; };
      };
    };
}
```

Rust needs a CC toolchain for linking. On NixOS the system linker doesn't exist, so flazel provides both.

Wire the toolchains in `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_rust", version = "0.70.0")
bazel_dep(name = "rules_cc", version = "0.1.4")
bazel_dep(name = "flazel")

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
# (No host_tools.host_tools(...) tag: rules_rust declares the default repo
# itself, and the override discards the downloaded toolchain anyway.)
host_tools = use_extension("@rules_rust//rust:extensions.bzl", "rust_host_tools")

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

### Archives the lockfile cannot see

> **When you need this:** only for **strict-offline** builds, i.e. the hermetic
> `mkDerivation` path, where the sandbox has no network and the Nix-built
> repository cache is the *exclusive* source. In the dev shell the same cache
> has a network fallback, so a missing archive is just fetched on a cache miss.
> If your CI builds in the dev shell and you have no hermetic `mkDerivation`
> check, skip this whole section: omit `extraArchives`, don't commit
> `flazel-archives.json`, and don't run `flazel-lock-archives`. You lose only
> cold-cache pre-seeding, not correctness.

Module extensions that declare `reproducible = True` are deliberately omitted
from `MODULE.bazel.lock`, so their downloads (e.g. rules_rust's internal
crates such as tinyjson) are invisible to `mkBcrCaches`. The dev shell ships
`flazel-lock-archives`, which asks Bazel itself for every extension-generated
repo spec and writes the missing `(url, sha256)` list to `flazel-archives.json`.
For a strict-offline build, commit the manifest and wire it in:

```nix
caches = flazel.lib.mkBcrCaches {
  inherit pkgs;
  lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
  extraArchives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
};
```

Regenerate it alongside `MODULE.bazel.lock` after a dependency change; a stale
manifest fails loudly (the offline build names the missing archive).

## Bazel versions

flazel works with Bazel 7, 8 and 9. `pkgs.bazel` is the default; pick another
with the `bazel` argument of `mkDevShell` and `mkDerivation`:

```nix
devShells.default = flazel.lib.cc.mkDevShell {
  inherit pkgs caches;
  bazel = pkgs.bazel_9;
  toolchains.default = cfg;
};
```

- Headers of external repositories (every nixpkgs library) are system headers
  on every version (`external_include_paths`). Bazel 9's `cc_library` passes
  `includes` with `-I`, earlier versions with `-isystem`.
- The repository cache lives outside the workspace, in
  `${XDG_CACHE_HOME:-~/.cache}/flazel/repo-cache`, and `.bazelrc.nix` points
  Bazel at it. Bazel 9 refuses a cache inside the workspace, so remove any
  `--repository_cache` line from your own `.bazelrc`.
- `MODULE.bazel.lock` is specific to the Bazel version that wrote it. A project
  that checks several versions keeps one lockfile per extra version under
  `locks/`:

```nix
variants = flazel.lib.bazelVariants { inherit pkgs; root = ./.; };
checks = pkgs.lib.mapAttrs' (_: variant:
  pkgs.lib.nameValuePair "build${variant.suffix}" (flazel.lib.cc.mkDerivation {
    inherit pkgs cfg;
    inherit (variant) bazel;
    lockFile = variant.lockOverride;
    caches = flazel.lib.mkBcrCaches {
      inherit pkgs;
      lockFile = flazel.lib.parseLockFile variant.lockFile;
    };
    # name, src, bazelCommand, installPhase as usual
  })) variants;
devShells = builtins.mapAttrs (_: variant: flazel.lib.cc.mkDevShell { /* bazel, caches as above */ }) variants;
apps.update-locks = flazel.lib.mkUpdateLocksApp {
  inherit pkgs;
  shells = builtins.attrNames (removeAttrs variants [ "default" ]);
};
```

`nix run .#update-locks` writes `locks/<version>.lock` with each version's
Bazel; pass `archives = true` if the project commits `flazel-archives.json`.

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

### Windows

Windows executables and DLLs with mingw-w64, linked statically against the C
and C++ runtimes, so they need nothing but Windows system DLLs. 32-bit, from
nixpkgs' `pkgsCross.mingw32`; for 64-bit use `pkgsCross.mingwW64` the same way
(triple `x86_64-w64-mingw32`):

```nix
mingw32 = pkgs.pkgsCross.mingw32;
windowsCfg = flazel.lib.cc.mkConfig {
  inherit pkgs;
  toolchainName = "windows";
  gcc = mingw32.buildPackages.gcc;
  target = {
    triple = "i686-w64-mingw32";
    libc = mingw32.windows.mingw_w64;
    libcName = "mingw";
    threads = mingw32.windows.mcfgthreads;   # the compiler's thread runtime
  };
};
```

```bash
bazel build //... --platforms=@local_config_cc_windows//:platform
```

Executables get `.exe`, a `cc_shared_library` becomes a `.dll`. They run under
Wine (`tests/cc` runs its Windows check that way, headless).

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

## Selecting a toolchain

Every toolchain repo emits a platform, and `--platforms` with it selects exactly
that toolchain and its own `nixpkgsLibs`, also among several for the same
target (gcc and clang, glibc and musl):

```nix
toolchains = { default = gccCfg; clang = clangCfg; };
```

```bash
bazel build //...                                              # default (gcc)
bazel build //... --platforms=@local_config_cc_clang//:platform # clang
```

A dev shell or build makes two choices from the toolchains it provides, not
from the ones `MODULE.bazel` declares:

- **The default target**, what a plain `bazel build` builds for:
  `defaultToolchain` if given, else the toolchain named `default`, else the
  only one. Several toolchains, none named `default`, must say which.
- **The host toolchain**, which builds the build's own tools and serves every
  platform that does not name a toolchain: `@platforms//host`, and platforms
  you write yourself. It is `hostToolchain` if given, else the default target
  if that can build for the build machine, else the only toolchain that can.
  A shell whose default is a cross toolchain therefore builds its tools with
  the native one. If several native toolchains could, it must say which.

```nix
flazel.lib.cc.mkDevShell {
  inherit pkgs caches;
  toolchains = { windows = mingwCfg; gcc = gccCfg; clang = clangCfg; };
  defaultToolchain = "windows";
  hostToolchain = "gcc";
};
```

`mkDerivation` provides one toolchain: it is the default target, and the host
toolchain if it can build for the build machine. The Rust builders take the same
choices as `defaultCcToolchain` and `hostCcToolchain`.

flazel never uses a compiler from `PATH`: `.bazelrc.nix` sets
`BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1`, also in a shell or build that provides no
CC toolchain. A build no flazel toolchain matches therefore fails in toolchain
resolution, naming the platform (the wording depends on the Bazel version),
instead of falling back to an autodetected gcc.

Every library variant comes from its toolchain's own `nixpkgsLibs`. Building
for a toolchain that does not provide a library fails, naming both, rather
than linking another toolchain's variant.

The choices are recorded in `.nix-bazel-deps/cc_toolchains.json`, which the
repository rules read. A `.nix-bazel-deps` written by an older flazel has no
such file, and every C++ build then fails until you re-enter the dev shell. The
host toolchain must be declared with `nix_cc.toolchain`, or builds that use it
fail with a message naming the missing declaration.

To have a hand-written platform select a toolchain other than the host one, add
that toolchain's `@local_config_cc_<name>//constraint:cc_toolchain` to its
`constraint_values`, or inherit it:

```starlark
platform(
    name = "my_platform",
    parents = ["@local_config_cc_clang//:platform"],
)
```

The same goes for platforms another rule set defines, such as
`@rules_rust//rust/platform:*`: without the constraint they select the host
toolchain if it fits them, and no flazel toolchain otherwise.

### Upgrading

Toolchain selection used to depend on registration order (the last registered
compatible toolchain won), and `--platforms=@local_config_cc_<name>//:platform`
did not select anything. After upgrading:

- A shell with several toolchains for the same target that passes no
  `--platforms` now builds with its default toolchain, and so do its exec tools.
  `{default, musl}`, for example, built with musl before and builds with gcc
  now.
- A project that already passed `--platforms=@local_config_cc_<name>//:platform`
  gets that toolchain for the first time. A clang configuration with
  `-Werror` or `layering_check` will now actually run clang, and may report
  what it never saw.
- Platforms from other rule sets need the constraint, as above.
- Re-enter the dev shell once, to write `.nix-bazel-deps/cc_toolchains.json`.
- Shells with several toolchains, none named `default`, must pass
  `defaultToolchain`; shells whose default cannot build for the build machine
  and that provide several that can must pass `hostToolchain`.
- A toolchain that does not list a library in its `nixpkgsLibs` no longer
  borrows another toolchain's variant.
- A Rust shell or derivation without `ccToolchains` no longer links with the
  system compiler: pass one in `ccToolchains`.

## Toolchain features

Bazel `--features=` flags wired to compiler/linker options.

### Default-on (opt out with `--features=-name`)

| Feature | Flags | When |
|---|---|---|
| `external_include_paths` | `-isystem` for headers of external repositories | always |
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

### Bazel modules from flake inputs (`moduleOverrides`)

A Bazel module that a flake provides, such as a rule set packaged with its
tools, is passed by store path. `mkDevShell` and `mkDerivation` turn each entry
into an `--override_module` line of `.bazelrc.nix`, and the store path becomes
an input of the build:

```nix
moduleOverrides = { mjolnir = mjolnir.packages.${system}.bazelModule; };
```

`MODULE.bazel` then names it without a version: `bazel_dep(name = "mjolnir")`.
flazel reaches every consumer the same way.

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

## Known limitations

- `lib.rust.mkDevShell` puts the first Rust toolchain by attribute name on
  `PATH` (rustc, cargo, clippy). With several Rust toolchains, which one that
  is follows their names, not a choice.

## References

- [Nix Flakes](https://nixos.wiki/wiki/Flakes): reproducible package management
- [Bazel](https://bazel.build/): incremental build system
- [rules_cc](https://github.com/bazelbuild/rules_cc): Bazel rules for C/C++
- [rules_rust](https://github.com/bazelbuild/rules_rust): Bazel rules for Rust
- [rust-overlay](https://github.com/oxalica/rust-overlay): pinned Rust toolchains for Nix
