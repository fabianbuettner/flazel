# Generate Bazel repository for a nixpkgs library
#
# Creates a Bazel-compatible repository with:
# - MODULE.bazel declaring the module
# - BUILD.bazel with cc_library/cc_import rules
# - include/ directory with headers
# - lib/ directory with static or dynamic libraries
#
# For static builds, transitive dependencies are bundled.
# For dynamic builds, libraries are symlinked directly.
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
  getTransitiveDeps ? (import ./utils.nix pkgs),
}:
let
  devPkg = pkg.dev or pkg;
  libPkg = pkg.out or pkg;
  pname = pkg.pname or pkg.name or name;

  # Check if a package is a library (has lib/*.a files)
  isLibrary =
    dep:
    let
      depLib = dep.out or dep;
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
        hdrs = glob(["include/**/*.h", "include/**/*.hpp", "include/**/*.ipp"], allow_empty = True),
        srcs = glob(["lib/**/*.so*", "lib/**/*.dylib"], allow_empty = True),
        includes = ["include"],
    )
  '';

  # Shell commands to copy static library files
  copyStaticLibs = ''
    mkdir -p $out/lib
    # Copy main package .a files
    if [ -d "${libPkg}/lib" ]; then
      cp -L "${libPkg}"/lib/*.a $out/lib/ 2>/dev/null || true
    fi
    # Copy transitive dep .a files
    ${builtins.concatStringsSep "\n" (
      map (
        dep:
        let
          depLib = dep.out or dep;
        in
        ''
          if [ -d "${depLib}/lib" ]; then
            cp -L "${depLib}"/lib/*.a $out/lib/ 2>/dev/null || true
          fi
        ''
      ) transitiveDeps
    )}
  '';

  # Shell commands to link dynamic library directory
  linkDynamicLibs = ''
    if [ -d "${libPkg}/lib" ]; then
      ln -s "${libPkg}/lib" $out/lib
    else
      mkdir -p $out/lib
    fi
  '';

  # Shell script to generate BUILD.bazel with cc_import rules
  # This runs at build time so we can discover actual .a filenames
  generateStaticBuild = ''
    # Check if there are any .a files
    a_files=$(find "$out/lib" -maxdepth 1 -name '*.a' -type f 2>/dev/null || true)

    if [ -z "$a_files" ]; then
      # Header-only library - just use cc_library
      cat > $out/BUILD.bazel <<'HEADERONLY'
    load("@rules_cc//cc:cc_library.bzl", "cc_library")

    package(default_visibility = ["//visibility:public"])

    cc_library(
        name = "${name}",
        hdrs = glob(["include/**/*.h", "include/**/*.hpp", "include/**/*.ipp"], allow_empty = True),
        includes = ["include"],
    )
    HEADERONLY
    else
      # Has static libraries - use cc_import
      # Find the main library file (try exact match first, then prefix match)
      main_lib=""
      if [ -f "$out/lib/lib${pname}.a" ]; then
        main_lib="lib${pname}.a"
      elif [ -f "$out/lib/${pname}.a" ]; then
        main_lib="${pname}.a"
      else
        # Try to find a library that starts with the pname
        main_lib=$(ls "$out/lib/" | grep -E "^lib${pname}[^a-z].*\.a$" | head -1 || true)
        if [ -z "$main_lib" ]; then
          # Fall back to first .a file
          main_lib=$(find "$out/lib" -maxdepth 1 -name '*.a' -type f | head -1 | xargs -r basename || true)
        fi
      fi

      # Collect all .a files as cc_import dependencies for the cc_library
      # Use -lib suffix to avoid name conflicts with the cc_library
      dep_imports=""
      for lib in $a_files; do
        [ -f "$lib" ] || continue
        libfile=$(basename "$lib")
        # Convert libfoo.a -> foo-lib (strip lib prefix and .a suffix, add -lib)
        dep_name=$(echo "$libfile" | sed 's/^lib//; s/\.a$//')
        dep_imports="$dep_imports\":$dep_name-lib\", "
      done

      # Generate BUILD.bazel with cc_library that has hdrs/includes
      # and depends on all cc_imports
      cat > $out/BUILD.bazel <<BUILDEOF
    load("@rules_cc//cc:cc_library.bzl", "cc_library")
    load("@rules_cc//cc:cc_import.bzl", "cc_import")

    package(default_visibility = ["//visibility:public"])

    cc_library(
        name = "${name}",
        hdrs = glob(["include/**/*.h", "include/**/*.hpp", "include/**/*.ipp"], allow_empty = True),
        includes = ["include"],
        deps = [$dep_imports],
    )
    BUILDEOF

      # Generate cc_import for each .a file (with -lib suffix)
      for lib in $a_files; do
        [ -f "$lib" ] || continue
        libfile=$(basename "$lib")
        dep_name=$(echo "$libfile" | sed 's/^lib//; s/\.a$//')
        cat >> $out/BUILD.bazel <<DEPEOF

    cc_import(
        name = "$dep_name-lib",
        static_library = "lib/$libfile",
    )
    DEPEOF
      done
    fi
  '';
in
pkgs.runCommand "nixpkgs-${name}" { } ''
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
        # Static: copy .a files first, then generate BUILD.bazel dynamically
        ${copyStaticLibs}
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
