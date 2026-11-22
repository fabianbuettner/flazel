# Generate Bazel repository for a nixpkgs library
#
# Creates a Bazel-compatible repository with:
# - MODULE.bazel declaring the module
# - its BUILD file (constants.nix generatedBuild) with cc_library/cc_import rules
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
  inherit (import ../core/constants.nix) generatedBuild;
  # Where a package keeps its libraries: the `lib` output when it splits one out
  # (e.g. brotli), otherwise `out`. Resolving `out` alone dropped split-output
  # libs from the static closure.
  archiveOutput = p: p.lib or p.out or p;

  devPkg = pkg.dev or pkg;
  libPkg = archiveOutput pkg;

  # Installed headers are often not self-contained (harfbuzz's "Include <hb.h>
  # instead"), and not this build's to check.
  packageDecl = ''package(default_visibility = ["//visibility:public"], features = ["-parse_headers"])'';

  # Header glob shared by every generated cc_library (dynamic, header-only, static):
  # include/ and any other include directory the consumer's pkg-config modules name
  # (glib's lib/glib-2.0/include). No extension filter: headers include .inc, .def and
  # extensionless files.
  hdrsGlob = ''glob(["include/**"] + [d + "/**" for d in INCLUDES], allow_empty = True)'';

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

  # Every output a pkg-config file of this package can describe, own -I directories included.
  ownOutputs = pkgs.lib.unique [
    devPkg
    libPkg
    (pkg.out or pkg)
  ];

  # Describe each pkg-config module the package ships in pkgconfig.json: the -I directories
  # its own Cflags name, as `includes` relative to this repo when they lie under the
  # package's include/ or lib/, as `foreign` when they lie in another store path, and as
  # `unplaced` when they lie in the package but under neither. The repository rule picks
  # the modules a consumer names; Nix cannot know them. Requires lines are dropped before
  # pkgconf reads a file: they name other packages, whose .pc files are not here and whose
  # directories come from those packages' own repos.
  #
  # A lib/ directory is placed in the repo where the dynamic layout already has it, through
  # the lib symlink; the static layout's lib/ holds only the merged archive, so it is linked.
  describePkgconfig = ''
    pcdir=$TMPDIR/pkgconfig
    mkdir -p "$pcdir"
    for d in ${
      pkgs.lib.concatMapStringsSep " " (o: "${o}/lib/pkgconfig ${o}/share/pkgconfig") ownOutputs
    }; do
      [ -d "$d" ] || continue
      for pc in "$d"/*.pc; do
        [ -e "$pc" ] || continue
        module=$(basename "$pc" .pc)
        [ -e "$pcdir/$module.pc" ] && continue
        grep -vE '^Requires(\.private)?[[:space:]]*:' "$pc" > "$pcdir/$module.pc" || true
        echo "$d" > "$pcdir/$module.pcfiledir"
      done
    done

    json_list() {
      local sep="" item
      printf '['
      for item in "$@"; do
        printf '%s"%s"' "$sep" "$item"
        sep=", "
      done
      printf ']'
    }

    {
      printf '{'
      msep=""
      for pc in "$pcdir"/*.pc; do
        [ -e "$pc" ] || continue
        module=$(basename "$pc" .pc)
        # A file pkgconf cannot read is recorded, not fatal: only a consumer naming the
        # module has a reason to fail.
        # pkgconf would read pcfiledir as the copy's directory; it is the original's.
        if ! flags=$(PKG_CONFIG_PATH="$pcdir" PKG_CONFIG_SYSTEM_INCLUDE_PATH="" \
          pkgconf --env-only --keep-system-cflags --define-variable=pcfiledir="$(cat "$pcdir/$module.pcfiledir")" \
          --cflags-only-I "$module" 2>/dev/null); then
          printf '%s"%s": {"unreadable": true}' "$msep" "$module"
          msep=", "
          continue
        fi
        includes=() foreign=() unplaced=()
        for flag in $flags; do
          dir=$(realpath -m -s "''${flag#-I}")
          case "$dir" in
            ${devPkg}/include | ${devPkg}/include/*)
              rel="include''${dir#${devPkg}/include}" ;;
            ${libPkg}/lib | ${libPkg}/lib/*)
              rel="lib''${dir#${libPkg}/lib}"
              if [ -e "$dir" ] && [ ! -e "$out/$rel" ]; then
                mkdir -p "$(dirname "$out/$rel")"
                ln -s "$dir" "$out/$rel"
              fi ;;
            ${pkgs.lib.concatMapStringsSep " | " (o: "${o} | ${o}/*") ownOutputs})
              unplaced+=("$dir"); continue ;;
            *)
              foreign+=("$dir"); continue ;;
          esac
          case " ''${includes[*]} " in
            *" $rel "*) ;;
            *) includes+=("$rel") ;;
          esac
        done
        printf '%s"%s": {"includes": %s, "foreign": %s, "unplaced": %s}' "$msep" "$module" \
          "$(json_list "''${includes[@]}")" "$(json_list "''${foreign[@]}")" "$(json_list "''${unplaced[@]}")"
        msep=", "
      done
      printf '}\n'
    } > $out/pkgconfig.json
  '';

  # Bazel stages a `srcs` .so into _solib_x86_64/ and links dependents with a relative
  # $ORIGIN runpath, which resolves only at the depth it assumes. Store paths are
  # immutable, so naming the directory outright always resolves; DT_RUNPATH is ordered,
  # so the relative entry still wins when present.
  rpathAttr = "\n    linkopts = [\"-Wl,-rpath,${libPkg}/lib\"],";

  # BUILD file content for dynamic linking. Takes the rpath attribute so the header-only
  # case can drop it without a second copy of the rule.
  dynamicBuildContent = linkoptsAttr: ''
    load("@rules_cc//cc:cc_library.bzl", "cc_library")
    load(":package_attrs.bzl", "INCLUDES", "SHARED_LIB_PATTERNS")

    ${packageDecl}

    cc_library(
        name = "${name}",
        hdrs = ${hdrsGlob},
        # Which shared libraries to link. Written by the nix_cc repository rule, which
        # defaults to every TOP-LEVEL one: files under lib/<pkg>/ are runtime plugins /
        # LD_PRELOAD shims (cairo-trace, gstreamer plugins, pango modules, etc.) and must
        # not be added to DT_NEEDED. A consumer that names its libs gets only those, so a
        # package's unused siblings stop contributing DT_NEEDED entries and global symbols.
        srcs = glob(SHARED_LIB_PATTERNS, allow_empty = True),
        includes = INCLUDES,${linkoptsAttr}
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

  # Symlink the library directory and write the matching BUILD file: one build-time
  # test of lib/ serves both. Build-time on purpose -- builtins.pathExists on a store
  # path realises it (import from derivation).
  generateDynamicBuild = ''
    if [ -d "${libPkg}/lib" ]; then
      ln -s "${libPkg}/lib" $out/lib
      cat > $out/${generatedBuild} <<'DYNEOF'
    ${dynamicBuildContent rpathAttr}
    DYNEOF
    else
      # Header-only: nothing to point an rpath at, and no .so to resolve.
      mkdir -p $out/lib
      cat > $out/${generatedBuild} <<'DYNHEADERONLY'
    ${dynamicBuildContent ""}
    DYNHEADERONLY
    fi
  '';

  # Generate the BUILD file for a static repo. One merged archive (when present)
  # becomes one cc_import wrapped in the cc_library; a header-only package (no
  # archives) is just the cc_library with its includes.
  generateStaticBuild = ''
    if [ -e "$out/${mergedArchive}" ]; then
      cat > $out/${generatedBuild} <<'STATICEOF'
    load("@rules_cc//cc:cc_library.bzl", "cc_library")
    load("@rules_cc//cc:cc_import.bzl", "cc_import")
    load(":package_attrs.bzl", "INCLUDES")

    ${packageDecl}

    cc_import(
        name = "${name}_archive",
        static_library = "${mergedArchive}",
    )

    cc_library(
        name = "${name}",
        hdrs = ${hdrsGlob},
        includes = INCLUDES,
        deps = [":${name}_archive"],
    )
    STATICEOF
    else
      # Header-only library - just a cc_library with includes.
      cat > $out/${generatedBuild} <<'HEADERONLY'
    load("@rules_cc//cc:cc_library.bzl", "cc_library")
    load(":package_attrs.bzl", "INCLUDES")

    ${packageDecl}

    cc_library(
        name = "${name}",
        hdrs = ${hdrsGlob},
        includes = INCLUDES,
    )
    HEADERONLY
    fi
  '';
in
pkgs.runCommand "nixpkgs-${name}"
  {
    # ar/ranlib to merge the static archive (build-time host tools; the archive
    # format is arch-independent, so host binutils handles musl/cross archives).
    nativeBuildInputs = [
      pkgs.buildPackages.pkgconf-unwrapped
    ]
    ++ pkgs.lib.optionals static [ pkgs.binutils ];
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
          # Static: merge the archive closure into one .a, then generate the BUILD file.
          ${mergeStaticLibs}
          ${generateStaticBuild}
        ''
      else
        ''
          # Dynamic: symlink the libraries, then generate the BUILD file.
          ${generateDynamicBuild}
        ''
    }

    ${describePkgconfig}
  ''
