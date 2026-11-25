# flazel

Nix pins your toolchain. Bazel builds your code. Nothing else required.

One `nix develop` gives you a hermetic compiler, linker and libc. One `bazel build` gives you file-level incremental caching. After setup, the builds the archive manifest covers need no network, and the only host dependency is Nix. "My machine" is a derivation, and every machine runs the same one.

## Features

### C/C++

- **GCC or Clang**: GCC 13 or later for hosted toolchains (Clang links its libstdc++ too) unless you set `target.linkFlags`, and any Clang nixpkgs has. Pick your linker: mold, lld, gold, bfd.
- **Static** (musl), **dynamic** (glibc), or **bare metal** (no libc). Your choice, one parameter.
- **Cross-compilation**: x86_64, aarch64, riscv32, riscv64, mips64, arm, and 32- and 64-bit Windows (mingw-w64). All in one shell.
- **Nixpkgs libraries**: `nixpkgsLibs = { openssl = pkgs.openssl; }` in Nix, `@openssl//:openssl` in Bazel. Transitive deps handled.
- **Hardened by default**: `_FORTIFY_SOURCE=3`, stack protectors, GLIBCXX assertions, split DWARF. Opt out per feature if you dare.
- **Sanitizers**: `asan`, `ubsan`, `tsan` as `--features=` flags. Mutual exclusion enforced. ASan+UBSan layering works.
- **Header checks**: `layering_check` (clang) and `parse_headers` (clang, GCC 15+). Find your missing `deps` and non-self-contained headers before CI does.
- **Build tuning**: `lto`, `gc_sections`, `hidden_visibility`, `gdb_index`
- **Coverage**: gcov and llvm-cov via `bazel coverage`

### Rust

- **Nix-provided rustc** threaded into Bazel (rules_rust downloads unpatched ELF binaries that segfault on NixOS. flazel uses rust-overlay's patchelf'd toolchain instead)
- **crate_universe**: Cargo deps resolved to Bazel targets. rules_rust's splice needs a host rustc that segfaults on NixOS; flazel overrides it with the Nix toolchain. Vendor the defs for fully offline builds (see [Offline Rust](#offline-rust))
- **Cross-compilation**: `aarch64-apple-ios`, `aarch64-unknown-linux-musl`, anything rustc supports
- **Dev shell**: rustc, cargo, clippy, rustfmt, nextest, cargo-llvm-cov, cargo-deny, bacon

### SystemVerilog

- **Verilator from nixpkgs** behind the upstream `rules_verilator` and `rules_verilog`: RTL becomes a `cc_library`, tested with ordinary `cc_test`s. Tracing (VCD, FST) and `--timing` work. See [SystemVerilog with Verilator](#systemverilog-with-verilator)

### Shared

- **Offline builds**: the archives the probed builds fetch (BCR modules, extension repos, vendored crates) pre-fetched into the Nix store. Once `flazel-lock-archives` has recorded them, those builds run without network; anything it did not observe is fetched online.
- **`/usr/bin/env` in the Nix build**: actions may run scripts that start `#!/usr/bin/env bash` (bazel_skylib's `diff_test`, for one). Every flazel derivation runs Bazel through `flazel.lib.bazelWithUsrBinEnv { pkgs, bazel }`, which on a Linux build machine:
  - runs plain Bazel where `/usr/bin/env` exists (Nix sandbox off, an ordinary distribution);
  - where `/usr` is absent, as in the Nix build sandbox, runs Bazel under bubblewrap in a root that adds Nix coreutils' `env` at `/usr/bin/env`. That needs a user namespace, as Bazel's `linux-sandbox` does. Where bwrap cannot set it up the build fails with bwrap's message naming the cause, and where the namespace cannot be created at all (`max_user_namespaces` exhausted, a container without `CAP_SYS_ADMIN`) flazel adds a note saying why bwrap ran;
  - refuses a `/usr` without `env` (unsupported): adding `env` would write into a filesystem flazel does not own.

  On other build platforms it is Bazel unchanged, and dev shells use plain Bazel, relying on the host's `/usr/bin/env`. `env` finds `bash` on the action `PATH` that nixpkgs' Bazel sets to store paths, so a build that forces `--action_env=PATH=/bin:/usr/bin` gets `env: 'bash': No such file or directory`.
- **Nix perl for rules_perl**: `perl = pkgs.perl` runs `rules_perl` exec tools and the exec `$(PERL)` with it, and host-targeted `rules_perl` targets and their `$(PERL)`. Under a Windows target, `rules_perl` itself breaks the exec `$(PERL)` by turning its `/` into `\`. See [Perl](#perl)
- **Non-BCR deps**: declared once in `flake.nix`, not duplicated in `MODULE.bazel`
- **Two lockfiles to bind them**: `flake.lock` pins nixpkgs, `MODULE.bazel.lock` pins Bazel deps. Together they fully determine every build input. The archives a build fetches live in a committed `flazel-archives.json`, written by `flazel-lock-archives` (see [The archives a build fetches](#the-archives-a-build-fetches)).

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
        # See "The archives a build fetches"; a new project starts from `[]`.
        archives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
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

## Nixpkgs libraries in Bazel

Each entry of `nixpkgsLibs` becomes a Bazel repository once `MODULE.bazel` declares it:

```starlark
nix_cc = use_extension("@flazel//bazel:nix_cc.bzl", "nix_cc")
nix_cc.package(name = "zlib")
nix_cc.package(
    name = "poppler",
    libs = ["poppler"],
    pkgconfig = ["poppler"],
)
use_repo(nix_cc, "poppler", "zlib")
```

`@poppler//:poppler` is then a `cc_library` over the package's headers and shared libraries.

- `name`: the key in `nixpkgsLibs`, and the repository's name.
- `libs`: the shared libraries to link, without the `lib` prefix or extension. Empty links
  every top-level `.so` the package ships, each of which also lands in `DT_NEEDED`.
- `pkgconfig`: pkg-config modules whose own `-I` directories join `include/` on the include
  path. `poppler.pc` names `include/poppler`, where poppler's core headers include each other
  by bare name. A directory inside the package is kept, `lib/` included (glib's
  `lib/glib-2.0/include`); one in another store path is dropped, since that package's own
  repository provides it (cairo.pc names freetype's). A module the package does not ship, one
  pkgconf cannot read, one naming only directories outside the package, or one naming a
  directory inside it but under neither `include/` nor `lib/` fails the library's analysis,
  naming the module.

Modules are named, not taken from every `.pc` file a package ships, because one package's
modules can disagree: poppler's `cpp` and `glib` bindings each ship a `poppler-document.h`, and
a union of their directories would pick one silently.

Without `pkgconfig` the generated target is unchanged: `include/` alone, as before the
attribute existed.

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
        # See "The archives a build fetches"; a new project starts from `[]`.
        archives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
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
bazel_dep(name = "rules_cc", version = "0.2.27")
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

### The archives a build fetches

`mkBcrCaches` takes the registry files from the lockfile and every archive
from `archives`, the manifest `flazel-lock-archives` writes. The lockfile
cannot say which archives a build fetches: it names every module the version
resolution visited, also those no build reads (whose archive may sit on a
mirror long gone), records what an extension could create rather than the
few repos a build reads, omits extensions declaring `reproducible = True`
outright (rules_rust's internal crates, such as tinyjson), and records
neither the root module's `use_repo_rule` repos nor an `archive_override`'s
archive. The dev shell ships `flazel-lock-archives`, which asks Bazel for the
specs of all of these (module archives with their registry patches and
overlay files included), analyzes the build against an empty repository
cache, and keeps the archives that were fetched. Commit the manifest and wire
it in:

```nix
caches = flazel.lib.mkBcrCaches {
  inherit pkgs;
  lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
  archives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
};
```

```
flazel-lock-archives [--check] [--output PATH]
                     [-- BAZEL_BUILD_ARGS... [--and BAZEL_BUILD_ARGS...]...]
```

Bazel arguments default to `//...`; pass the targets and `--config` of every
offline build. Each `--and`-separated group is analyzed on its own and the
manifest is the union of what they fetch, so a project building several target
configurations (`--platforms`, `--config`s, `--define`s that select different
dependencies) passes one group each:

```
flazel-lock-archives -- //... --and --config=windows //app:installer
```

The groups vary the target configuration, not the host. A manifest is observed
on the host that runs the tool and is shared by every system the flake builds
for, so a download that depends on the host (an exec toolchain, an extension
that picks by OS or architecture) is recorded only for the probing host; a
build on another host needs a probe there.

The groups go to `bazel build --nobuild`, so options under `test:` in
`.bazelrc` are not applied. The tool reads `MODULE.bazel.lock`, never writes
it, and fails if it is stale: after a dependency change, refresh the lockfile
first, then the manifest (`update-locks` does both). `--check` derives it
afresh, with the same groups, and compares it with the committed file,
printing the urls of each `missing:` and `extra:` download and exiting 3 on
any difference, so a CI step catches a stale manifest in both directions. Any
other failure (a missing file, a failed probe build) exits with another
non-zero status. A `git_override`, and any module download without a sha256
integrity, are refused.

`parseArchiveManifest` fails evaluation when the file is absent, so a manifest
that is not tracked by git cannot silently empty the cache. The dev shell
evaluates it too: a project adopting one starts from a file holding `[]`, and
its dev shell fetches on a cache miss until the manifest is written. The
manifest is empty only when the resolution declares no archive; if it
declares some and the builds fetch none, the tool refuses to write it.

## SystemVerilog with Verilator

`rules_verilator` depends on a BCR module `verilator` that compiles Verilator
from source. `flazel.lib.hdl.mkVerilatorModule` builds a module of that name
from a nixpkgs Verilator instead, and `moduleOverrides` puts it in its place:

```nix
moduleOverrides.verilator = flazel.lib.hdl.mkVerilatorModule {
  inherit pkgs;
  inherit (pkgs) verilator;
};
```

Pass it to `mkDevShell` and `mkDerivation` alike. `MODULE.bazel` declares only
the rule sets:

```starlark
bazel_dep(name = "rules_verilator", version = "1.1.2")
bazel_dep(name = "rules_verilog", version = "1.4.2")
```

Older `rules_verilator` releases report a failed Verilator run as success.
Complete working example, RTL checked against a C++ model: [`tests/hdl/`](tests/hdl/).

## Perl

`rules_perl` downloads prebuilt perls and registers them as its toolchains.
Pass `perl` to `mkDevShell` and `mkDerivation` alike to run its exec tools,
the exec `$(PERL)` and host-targeted targets with a nixpkgs perl instead:

```nix
perl = pkgs.perl;
```

flazel then registers `@nix_perl//:all` in `.bazelrc.nix`, ahead of
`rules_perl`'s own toolchains, for the host as target and as exec platform.
flazel has no dependency on `rules_perl`, so `MODULE.bazel` declares it and
the repo:

```starlark
bazel_dep(name = "platforms", version = "1.0.0")
bazel_dep(name = "rules_perl", version = "2.0.0")

nix_perl = use_repo_rule("@flazel//bazel:nix_perl.bzl", "nix_perl")
nix_perl(name = "nix_perl")
```

The toolchain builds no XS modules. Without `perl`, `rules_perl` uses the
perl it downloads, also in the dev shell. Complete working example:
[`tests/perl/`](tests/perl/).

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
      archives = flazel.lib.parseArchiveManifest variant.archives;
    };
    # name, src, bazelCommand, installPhase as usual
  })) variants;
devShells = builtins.mapAttrs (_: variant: flazel.lib.cc.mkDevShell { /* bazel, caches as above */ }) variants;
apps.update-locks = flazel.lib.mkUpdateLocksApp {
  inherit pkgs;
  shells = builtins.attrNames (removeAttrs variants [ "default" ]);
  # One Bazel argument list per configuration the checks build.
  probes = [ [ "//..." ] ];
};
```

`nix run .#update-locks` refreshes `MODULE.bazel.lock` with the default
Bazel and writes `locks/<version>.lock` with each version's. After refreshing
each lock it writes that lock's manifest, `flazel-archives.json` and
`locks/<version>.archives.json`, observing one build per entry of `probes`.
A project with a single Bazel passes `shells = [ ]` and gets no `locks/`.

`nix run .#update-locks -- --check` changes no lock or manifest. It checks
`MODULE.bazel.lock` with `bazel mod deps --lockfile_mode=error` and, if the
lock is current, `flazel-archives.json` with `flazel-lock-archives --check`,
using the same `probes`. It names each file that is missing or fails the
check, and exits 1, so a CI step catches either going stale; no other
outcome exits 1. Bazel exits alike for a stale lock and for any other
error, so a stale lock is told by Bazel's own messages, those asking to
"update your lockfile" and those naming what "does not exist in the
lockfile" (the patterns are in `lib/core/update-locks.nix`). A check that
cannot run (any other Bazel error, such as a `MODULE.bazel` syntax error
or an unreachable registry, or a `flazel-lock-archives` failure other
than a differing manifest, such as a failed probe build) stops the check
with 8, naming the file after the tool's own error. A wrong argument
exits 2, an interrupt 130 or 143. A dev shell that Nix fails to evaluate
(`nix print-dev-env`), or whose setup exits (a `shellHook` that calls
`exit`), stops either mode with 7; the check names what failed before it
stops with 5, 6, 7 or 8. Update mode stops on any other failure with 8,
naming the files after the tool's own error, so 1 stays a stale file's
and 2 a wrong argument's. A command the app runs in a dev shell that
fails, or a function from its setup that exits (a `bazel()` wrapper
calling `exit`), stops either mode with 8, whatever its status, so 5, 6
and 7 are the app's own. If the app itself is killed, the check ends with
it, except on darwin, where it runs to its end. With Bazel-version shells
it checks each version's `locks/<version>.lock` and manifest the same way;
without `MODULE.bazel.lock`, which each version's lock is mounted over, it
checks no version and names each as not checked. Each mode keeps the dev
shell setups Nix evaluated in a scratch directory under `$TMPDIR`, removed
when the app ends, unless it is killed with SIGKILL; one it cannot make
stops it with 8. Each setup is sourced into the shell that runs Bazel,
default and versions alike, so a `shellHook`'s functions and unexported
variables (a `bazel()` wrapper, say) apply too. Nix runs with stdin from
`/dev/null`, so it cannot ask about a flake's `nixConfig` and ignores
settings not yet trusted: accept them once interactively (`nix develop`),
or run the app with `NIX_CONFIG='accept-flake-config = true'`
(`nix run --accept-flake-config` does not reach the Nix the app runs).

The default Bazel runs in the project directory as it is. Each other version,
in both modes, runs there too, in a private mount and pid namespace
(bubblewrap, so variants need Linux; on darwin an app with shells refuses).
Nix evaluates its dev shell outside, against the project as it is. Inside,
its lock is mounted over `MODULE.bazel.lock`, and its manifest is written to
`locks/<version>.archives.json` directly (`flazel-lock-archives --output`).
tmpfs mounts hold the `.nix-bazel-deps` its dev shell writes, the default
Bazel's output base and the directory of its install base (as `bazel info`
reports them, so also ones a `.bazelrc` sets) and its `TMPDIR`, which holds
the dev shell setup Nix evaluated, so the version's output base, install
base and the repositories its probes fetch live in RAM. Bazel's repository
cache is not among them: each version's downloads land in the shared
on-disk cache, which is content-addressed, so no version fetches an archive
another already has. If the version's Bazel reports other bases, the app
exits 5 before that Bazel runs a command (`bazel info` itself may already
have created them), and so it does if a mount would hide the project
(symlinks resolved); the default Bazel or a version's that cannot answer
`bazel info`, or a `.nix-bazel-deps` the app cannot make, stops it with 8.
If the namespace cannot be made (no user namespaces, a mount in it that
fails, or darwin), it exits 6. Outside, Nix evaluations and the default dev
shell keep seeing the project's own files; untracked files and overrides
pointing outside the project apply as in the default shell.
When the namespace ends, even by SIGKILL of the app, everything in it ends
too, Bazel's server included, and an interrupted app returns only after
that. A version's lock under `locks/` is replaced whole. Update mode stops
on an interrupt or the app's death as the check does.

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

The compiler identifies as `mingw-gcc`, as rules_cc names it, so a `select()`
on `@rules_cc//cc/compiler:mingw-gcc` picks it and one on `:gcc` does not.
BCR modules that select on `:gcc` alone (abseil's warning copts, highway) take
their default branch on mingw.

`std::stacktrace` links and runs on 32- and 64-bit, but under Wine a 64-bit
trace names no frames: libstdc++'s libbacktrace, given no executable name, reads
`/proc/self/exe`, which is Wine's ELF loader. nixpkgs' 32-bit mingw-w64 GCC uses
SJLJ exceptions, whose unwinder walks no frames, so its traces are empty.

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

A clang toolchain adds `template_diagnostics` and the
[header checks](#header-checks) `layering_check` and `parse_headers`.

## Header checks

`layering_check` needs clang. `parse_headers` needs clang or GCC 15 or later.
Any other compiler does not offer the feature it cannot do, and Bazel ignores a
request for a feature a toolchain does not have, silently. Both are opt-in: a
build that requests neither compiles with exactly the command lines it would
without them.

```bazelrc
build:clang-check --platforms=@local_config_cc_clang//:platform
build:clang-check --features=layering_check
build:clang-check --features=parse_headers
build:clang-check --process_headers_in_dependencies
```

- `layering_check` fails a compile that includes a header from a target that
  is not a direct dependency. It passes each target's module map and its
  dependencies' (`-fmodule-name`, `-fmodule-map-file`,
  `-fmodules-strict-decluse`). System headers belong to the toolchain's
  `crosstool` module, generated from its builtin include directories.
- `parse_headers` compiles every header in `hdrs` and `srcs` on its own
  (`-xc++-header -fsyntax-only`), so a header that is not self-contained fails.
  It parses with the same `-O`, `-D` and warning flags as the target's sources,
  `_FORTIFY_SOURCE` under `-c opt` included. A target whose headers are C sets
  `features = ["parse_headers_as_c"]`, which parses them with `-xc-header` and
  the C standard instead of the C++ one.
- `--process_headers_in_dependencies` is what makes `bazel build` run the
  header-parse actions, for the requested targets and everything they depend
  on. Without it `parse_headers` creates the actions and nothing requests them,
  on Bazel 7, 8 and 9 alike.
- `module_maps` is enabled whenever the toolchain is clang, as in rules_cc's
  own clang toolchain. It adds no flag; it has Bazel write a `.cppmap` per
  target, which the two features above read.

On GCC, `parse_headers` also passes `-Wno-pragma-once-outside-header`: GCC
reports `#pragma once` in the header it parses as the main file. GCC 14 and
earlier cannot silence that, which is why they do not offer `parse_headers`.
On clang it passes `-Wno-unused-command-line-argument` for the `-c` Bazel
gives every compile, which `-fsyntax-only` leaves unused.

Headers of nixpkgs libraries are not parsed: their generated packages set
`features = ["-parse_headers"]`, since many of them are meant to be included
only through an umbrella header. Repositories flazel does not generate, such
as BCR modules, are parsed under `--process_headers_in_dependencies` like your
own code, and some fail (headers that are templates, or that must not be
included directly). Bazel has no per-repository `--features`; opt such a
module out with a `REPO.bazel` patched in through its override:

```starlark
# MODULE.bazel
single_version_override(
    module_name = "zlib-ng",
    patches = ["//third_party:zlib-ng-no-parse-headers.patch"],
)
```

```diff
# third_party/zlib-ng-no-parse-headers.patch
--- /dev/null
+++ REPO.bazel
@@ -0,0 +1 @@
+repo(features = ["-parse_headers"])
```

A module that already ships a `REPO.bazel` needs the `features` argument added
to its `repo()` call instead.

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

The `cc_toolchain` value is a choice of compiler, not something a machine has.
Each toolchain therefore registers a test toolchain that runs its platform's
tests on any execution platform with the same cpu and os, the host included.
Bazel 9's default one would demand every target constraint of the execution
platform, `cc_toolchain` with them, and find none. Exec tools are unaffected:
they are still built with the host toolchain.

- Like Bazel's own, it steps aside under `--use_target_platform_for_tests`.
- It cannot see `--@bazel_tools//tools/test:incompatible_use_default_test_toolchain=false`:
  Bazel declares that flag private, so no other repository can read it. With
  the flag, tests still run on an execution platform with the target's cpu and
  os, where Bazel's legacy toolchain would accept any.
- The C environment is not a machine property either, so tests for a
  freestanding toolchain whose cpu and os match the host now run on the host;
  before, they failed toolchain resolution.

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

`layering_check` and `parse_headers` used to be silently disabled: no
toolchain had a module map or declared header parsing, so Bazel dropped both
features without a word. After upgrading:

- A build that requests them gets them for the first time, and may report
  missing `deps` and headers that are not self-contained it never saw.
- With `--process_headers_in_dependencies`, BCR modules' headers are parsed
  too; opt out the ones that fail as described under [Header checks](#header-checks).
- `parse_headers` works with GCC 15 and later too; earlier GCC ignores it.
- A build that requests neither keeps its compile command lines. On clang,
  each C/C++ target gains a `.cppmap` action and the toolchain gains files, so
  the first build after upgrading recompiles.
- On Bazel 9, `bazel test` under a toolchain's platform used to fail with
  `No matching toolchains found for types:
  @@bazel_tools//tools/test:default_test_toolchain_type`, and needed
  `--extra_execution_platforms`. It now runs tests on the host; drop that flag.

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
| `split_debug` | `-gsplit-dwarf` | `-c dbg`, ELF targets |
| `gc_sections` | `-ffunction-sections -fdata-sections -Wl,--gc-sections` | `-c opt` |
| `bind_now` | `-Wl,-z,now` | Linux targets (ELF), a no-op for static links; not bare metal, Windows or macOS |

`bind_now` turns the RELRO every supported linker already applies into full
RELRO. A consumer wants it here rather than as `--linkopt=-Wl,-z,now`, which
mingw-w64's linker rejects and which Bazel cannot drop for one platform.

`c_flags` compiles C in the dialect `cStandard` in `mkConfig` selects, without
`__STRICT_ANSI__` and with `-fasm`, external repositories included. libc headers
hide declarations C libraries expect, like `setenv` or mingw-w64's `M_PI`, under
`__STRICT_ANSI__`; without it C sees the libc headers' GNU declarations, and
`-fasm` gives back the GNU keywords an ISO dialect turns off (`asm`, `typeof`;
they cannot be identifiers then), while under an ISO dialect GCC keeps its
semantics, such as its floating-point rules, that a GNU dialect would change.

`cxx_flags` defines `_GNU_SOURCE` for C++ on Windows targets, as Linux g++
predefines it and mingw-w64's does not, so declarations like `M_PI` are visible
on both.

### Opt-in

| Feature | Flags | Notes |
|---|---|---|
| `gdb_index` | `-Wl,--gdb-index` | needs gold, lld, or mold |
| `warnings` | `-Wall -Wextra` | |
| `warnings_pedantic` | adds `-Wpedantic -Wconversion` and more | full list in `lib/cc/cc_toolchain_config.bzl`; C gets only the ones C has |
| `treat_warnings_as_errors` | `-Werror` | |
| `asan` | `-fsanitize=address -fno-omit-frame-pointer` | `provides=["sanitizer"]` |
| `ubsan` | `-fsanitize=undefined` | layers with asan or tsan |
| `tsan` | `-fsanitize=thread` | `provides=["sanitizer"]` |
| `lto` | `-flto=thin` / `-flto=auto` | |
| `hidden_visibility` | `-fvisibility=hidden` | |
| `freestanding` | `-ffreestanding` | usually set via `target.freestanding = true` |
| `template_diagnostics` | `-fdiagnostics-show-template-tree` | Clang only |
| `layering_check` | `-fmodules-strict-decluse` and module maps | Clang only, see [Header checks](#header-checks) |
| `parse_headers` | `-xc++-header -fsyntax-only` per header | Clang or GCC 15+, see [Header checks](#header-checks) |
| `parse_headers_as_c` | `-xc-header` instead | per target, with `parse_headers` |

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

### Repositories and offline archives (`archives`)

A non-module **repository** (anything declared in `MODULE.bazel` via
`use_repo_rule`: `http_archive`, `http_file`) is not a `nonBcrDeps` entry.
`--override_repository` cannot redirect it: a `use_repo_rule` repo's canonical
name is `_main~_repo_rules~<name>`, which the flag does not match. Declare the
repo in `MODULE.bazel` the normal way (with its `integrity`/`build_file`);
`flazel-lock-archives` puts its archive in the manifest, as it does an
`archive_override`'s (see
[The archives a build fetches](#the-archives-a-build-fetches)).

`archives` is a list of `{ urls; sha256; canonical_id; }`, one per download,
seeded into the repo cache by sha256. Nix fetches from the urls in order.
Bazel finds a cached download only under the id it downloads with: the
`canonical_id` the repository sets, else its urls joined by spaces, so both
are recorded as the spec has them (`canonical_id` is `""` when unset). List
an archive by hand only when no Bazel resolution names it:

```nix
archives = flazel.lib.parseArchiveManifest ./flazel-archives.json ++ [
  {
    urls = [ "https://github.com/org/data/archive/v1.tar.gz" ];
    sha256 = "sha256-...";
    canonical_id = "";
  }
];
```

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
nix build  # same inputs, same result
```

## Properties

**Hermetic.** If it builds, it builds everywhere. No implicit host deps.

**Reproducible.** The same inputs give the same store path, because the path is a hash of the inputs. That the same inputs also give the same bits is a property of the build rather than of the hash, and `nix build --rebuild` is how you check it.

**Incremental.** Touch one `.cc` file, rebuild one target. Bazel tracks at file granularity.

**Offline.** Once the dev-shell closure is in your Nix store (first `nix develop`, an internal binary cache, or `nix copy` over sneakernet), `nix develop --offline` runs air-gapped, and so do the Bazel builds the manifest was observed for (see [The archives a build fetches](#the-archives-a-build-fetches)). A manifest holding `[]` caches nothing.

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
