# Generate Bazel repository for a nixpkgs library
#
# Creates a Bazel-compatible repository with:
# - MODULE.bazel declaring the module
# - BUILD.bazel with cc_library/cc_import rules
# - include/ directory with headers
# - lib/ directory with static or dynamic libraries
#
# For static builds, the package and its transitive static closure are merged
# into a single archive. For dynamic builds, libraries are symlinked directly.
#
# Usage:
#   repo = flazel.lib.mkNixpkgsRepo {
#     inherit pkgs;
#     name = "openssl";
#     pkg = pkgs.openssl;
#     static = true;
#   };
#
{
  pkgs,
  name,
  pkg,
  static ? false,
  getTransitiveDeps ? (import ../core/utils.nix pkgs),
}:
let
  # Where a package keeps its libraries: the `lib` output when it splits one out
  # (e.g. brotli), otherwise `out`. Resolving `out` alone dropped split-output
  # libs from the static closure.
  archiveOutput = p: p.lib or p.out or p;

  devPkg = pkg.dev or pkg;
  libPkg = archiveOutput pkg;

  # Header glob shared by every generated cc_library (dynamic, header-only, static)
  hdrsGlob = ''glob(["include/**/*.h", "include/**/*.hpp", "include/**/*.ipp"], allow_empty = True)'';

  # Check if a package is a library (has a lib/ with archives).
  isLibrary =
    dep:
    let
      depLib = archiveOutput dep;
    in
    builtins.pathExists "${depLib}/lib"
    && (dep.pname or dep.name or "") != ""
    && (dep.pname or dep.name or "") != "bash";

  # Get transitive deps (only needed for static linking)
  # Filter to only include actual libraries
  transitiveDeps = if static then builtins.filter isLibrary (getTransitiveDeps pkg) else [ ];

  # BUILD.bazel content for dynamic linking
  dynamicBuildContent = ''
    load("@rules_cc//cc:cc_library.bzl", "cc_library")

    package(default_visibility = ["//visibility:public"])

    cc_library(
        name = "${name}",
        hdrs = ${hdrsGlob},
        # Match only top-level shared libraries. Files under lib/<pkg>/ are
        # runtime plugins / LD_PRELOAD shims (cairo-trace, gstreamer plugins,
        # pango modules, etc.) and must not be added to DT_NEEDED.
        srcs = glob(["lib/*.so*", "lib/*.dylib"], allow_empty = True),
        includes = ["include"],
    )
  '';

  # Path (relative to $out) of the single merged archive produced for a static
  # library repo.
  mergedArchive = "lib/lib${name}.a";

  # Merge the package's own archive(s) and its whole transitive static closure
  # into ONE archive. A single archive is order-independent at link time: the
  # linker resolves references between its members regardless of member order,
  # so no cc_import ordering, link grouping, or --start-group is needed, and the
  # generated BUILD carries just one cc_import. `ar -M` (addlib) merges archives
  # member-wise and preserves duplicate member names, unlike extract+rearchive
  # which would clobber same-named objects. Cross-repo duplicate objects (a lib
  # bundled into several repos) stay harmless: without alwayslink the linker
  # pulls each on demand and the first definition wins.
  mergeStaticLibs = ''
    mkdir -p $out/lib
    archives=
    collect() {
      local libdir="$1"
      [ -d "$libdir" ] || return 0
      for a in "$libdir"/*.a; do
        [ -e "$a" ] && archives="$archives $a"
      done
    }
    collect "${libPkg}/lib"
    ${builtins.concatStringsSep "\n" (map (dep: ''collect "${archiveOutput dep}/lib"'') transitiveDeps)}
    if [ -n "$archives" ]; then
      {
        echo "create $out/${mergedArchive}"
        for a in $archives; do echo "addlib $a"; done
        echo "save"
        echo "end"
      } | ar -M
      ranlib "$out/${mergedArchive}"
    fi
  '';

  # Shell commands to link dynamic library directory
  linkDynamicLibs = ''
    if [ -d "${libPkg}/lib" ]; then
      ln -s "${libPkg}/lib" $out/lib
    else
      mkdir -p $out/lib
    fi
  '';

  # Generate BUILD.bazel for a static repo. One merged archive (when present)
  # becomes one cc_import wrapped in the cc_library; a header-only package (no
  # archives) is just the cc_library with its includes.
  generateStaticBuild = ''
    if [ -e "$out/${mergedArchive}" ]; then
      cat > $out/BUILD.bazel <<'STATICEOF'
    load("@rules_cc//cc:cc_library.bzl", "cc_library")
    load("@rules_cc//cc:cc_import.bzl", "cc_import")

    package(default_visibility = ["//visibility:public"])

    cc_import(
        name = "${name}_archive",
        static_library = "${mergedArchive}",
    )

    cc_library(
        name = "${name}",
        hdrs = ${hdrsGlob},
        includes = ["include"],
        deps = [":${name}_archive"],
    )
    STATICEOF
    else
      # Header-only library - just a cc_library with includes.
      cat > $out/BUILD.bazel <<'HEADERONLY'
    load("@rules_cc//cc:cc_library.bzl", "cc_library")

    package(default_visibility = ["//visibility:public"])

    cc_library(
        name = "${name}",
        hdrs = ${hdrsGlob},
        includes = ["include"],
    )
    HEADERONLY
    fi
  '';
in
pkgs.runCommand "nixpkgs-${name}"
  {
    # ar/ranlib to merge the static archive (build-time host tools; the archive
    # format is arch-independent, so host binutils handles musl/cross archives).
    nativeBuildInputs = pkgs.lib.optionals static [ pkgs.binutils ];
  }
  ''
    mkdir -p $out

    cat > $out/MODULE.bazel <<EOF
    module(name = "${name}")
    EOF

    mkdir -p $out/include
    if [ -d "${devPkg}/include" ]; then
      cp -rL "${devPkg}/include"/* $out/include/ 2>/dev/null || true
      # Flatten versioned subdirectories (e.g., openjpeg-2.5/)
      # Only flatten dirs that match a version pattern (contain hyphen + digit)
      for subdir in $out/include/*/; do
        if [ -d "$subdir" ]; then
          dirname=$(basename "$subdir")
          # Only flatten if dirname contains version pattern like -2.5 or -1.0
          if echo "$dirname" | grep -qE '.*-[0-9]+\.'; then
            cp -rL "$subdir"* $out/include/ 2>/dev/null || true
          fi
        fi
      done
    fi

    ${
      if static then
        ''
          # Static: merge the archive closure into one .a, then generate BUILD.bazel.
          ${mergeStaticLibs}
          ${generateStaticBuild}
        ''
      else
        ''
          # Dynamic: generate BUILD.bazel directly
          cat > $out/BUILD.bazel <<'DYNEOF'
          ${dynamicBuildContent}
          DYNEOF
          ${linkDynamicLibs}
        ''
    }
  ''
