# The CC toolchain decisions of a shell or build: the default target
# (--platforms) and the host toolchain; see README "Selecting a toolchain".
{
  pkgs,
  # Attrset of { name = cfg; } for every CC toolchain to register.
  toolchains,
  # The default target, or null for the one named "default", else the only one.
  defaultToolchain,
  # The host toolchain, or null for the default target if it can build for the
  # build machine, else the only toolchain that can.
  hostToolchain,
}:
let
  inherit (pkgs) lib;
  inherit (import ../core/constants.nix) nixDepsDir ccToolchainsFile;
  names = lib.attrNames toolchains;
  list = lib.concatStringsSep ", " names;

  chosen =
    what: name:
    if lib.elem name names then
      name
    else
      throw "flazel: ${what} \"${name}\" is not one of the CC toolchains ${list}";

  default =
    if defaultToolchain != null then
      chosen "defaultToolchain" defaultToolchain
    else if names == [ ] then
      null
    else if lib.elem "default" names then
      "default"
    else if lib.length names == 1 then
      lib.head names
    else
      throw "flazel: the CC toolchains ${list} include none named \"default\"; pass defaultToolchain = \"<name>\" to choose the one a plain `bazel build` targets";

  hosted = lib.filter (name: toolchains.${name}.targetsBuildPlatform) names;
  host =
    if hostToolchain != null then
      if toolchains.${chosen "hostToolchain" hostToolchain}.targetsBuildPlatform then
        hostToolchain
      else
        throw "flazel: hostToolchain \"${hostToolchain}\" cannot build for the build machine"
    else if default != null && toolchains.${default}.targetsBuildPlatform then
      default
    else if lib.length hosted <= 1 then
      # null for a cross-only set; a build needing exec tools fails resolution.
      lib.findFirst (_: true) null hosted
    else
      throw "flazel: the default CC toolchain \"${default}\" cannot build for the build machine and several others can (${lib.concatStringsSep ", " hosted}); pass hostToolchain = \"<name>\" to choose the one exec tools are built with";

  marker = pkgs.writeText "flazel-cc-toolchains.json" (
    builtins.toJSON {
      inherit host;
      provided = names;
    }
  );
in
{
  inherit default host;

  lines =
    # Never fall back to rules_cc's autodetected PATH compiler.
    "common --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1\n"
    + lib.concatMapStrings (
      name: "build --extra_toolchains=@local_config_cc_${name}//:cc_toolchain\n"
    ) names
    + lib.optionalString (default != null) "build --platforms=@local_config_cc_${default}//:platform\n";

  # Runs after the core setup, which defines flazel_put.
  setup = "flazel_put ${marker} ${nixDepsDir}/${ccToolchainsFile}\n";
}
