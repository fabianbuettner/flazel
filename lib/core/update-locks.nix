# An app that refreshes MODULE.bazel.lock with the default dev shell's Bazel,
# writes locks/<shell>.lock with the Bazel of each named dev shell, and the
# matching flazel-archives.json and locks/<shell>.archives.json via
# flazel-lock-archives, observing one build per entry of probes (a list of
# Bazel argument lists). Run it in the project directory.
{
  pkgs,
  shells,
  probes,
}:
let
  lockArchives = pkgs.writeShellScript "lock-archives" ''
    exec flazel-lock-archives -- ${
      pkgs.lib.concatMapStringsSep " --and " pkgs.lib.escapeShellArgs probes
    }
  '';
in
assert pkgs.lib.assertMsg (
  probes != [ ] && builtins.all (p: p != [ ]) probes
) "mkUpdateLocksApp: probes needs at least one non-empty Bazel argument list";
{
  type = "app";
  program = toString (
    pkgs.writeShellScript "update-locks" ''
      set -eu
      mkdir -p locks
      # Every lock is refreshed before its manifest is derived, because
      # flazel-lock-archives reads the lock and refuses a stale one.
      nix develop --command sh -ec '
        bazel shutdown
        trap "bazel shutdown" EXIT
        bazel mod deps --lockfile_mode=update >/dev/null
        ${lockArchives}
      '
      # Each iteration below starts from the refreshed lock and replaces the
      # live file, and overwrites the default manifest; the trap puts both
      # back, also when a run dies partway.
      trap '[ -f MODULE.bazel.lock.saved ] \
        && mv MODULE.bazel.lock.saved MODULE.bazel.lock || true
        [ -f flazel-archives.json.default ] \
        && mv flazel-archives.json.default flazel-archives.json || true' EXIT
      cp MODULE.bazel.lock MODULE.bazel.lock.saved
      cp flazel-archives.json flazel-archives.json.default
      ${pkgs.lib.concatMapStrings (shell: ''
        # Bazel rewrites the lockfile in its own format; the default one stays
        # in place because dev shells evaluate it. A server left running
        # rewrites it again when another version's client stops it.
        nix develop .#${shell} --command sh -ec '
          bazel shutdown
          trap "bazel shutdown" EXIT
          cp MODULE.bazel.lock.saved MODULE.bazel.lock
          bazel mod deps --lockfile_mode=update >/dev/null
          ${lockArchives}
        '
        mv flazel-archives.json locks/${shell}.archives.json
        mv MODULE.bazel.lock locks/${shell}.lock
      '') shells}
    ''
  );
}
