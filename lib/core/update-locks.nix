# An app that writes locks/<shell>.lock with the Bazel of each named dev shell
# and, with `archives`, locks/<shell>.archives.json via flazel-lock-archives.
# Run it in the project directory; the project's own files are left as they were.
{
  pkgs,
  shells,
  archives ? false,
}:
let
  saved = [ "MODULE.bazel.lock" ] ++ pkgs.lib.optional archives "flazel-archives.json";
in
{
  type = "app";
  program = toString (
    pkgs.writeShellScript "update-locks" ''
      set -eu
      mkdir -p locks
      ${pkgs.lib.concatMapStrings (file: "cp ${file} ${file}.saved\n") saved}
      trap '${pkgs.lib.concatMapStrings (file: "mv ${file}.saved ${file}; ") saved}' EXIT
      ${pkgs.lib.concatMapStrings (shell: ''
        # Bazel rewrites the lockfile in its own format; the default one stays
        # in place because dev shells evaluate it.
        cp MODULE.bazel.lock.saved MODULE.bazel.lock
        nix develop .#${shell} --command bazel mod deps --lockfile_mode=update >/dev/null
        ${pkgs.lib.optionalString archives ''
          nix develop .#${shell} --command flazel-lock-archives
          mv flazel-archives.json locks/${shell}.archives.json
        ''}
        mv MODULE.bazel.lock locks/${shell}.lock
      '') shells}
    ''
  );
}
