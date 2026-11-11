# An app that writes locks/<shell>.lock with the Bazel of each named dev shell
# and, with `archives`, locks/<shell>.archives.json via flazel-lock-archives,
# plus the default variant's own flazel-archives.json, which has no locks/
# counterpart and which nothing else would regenerate.
# Run it in the project directory; MODULE.bazel.lock is left as it was.
{
  pkgs,
  shells,
  archives ? false,
}:
{
  type = "app";
  program = toString (
    pkgs.writeShellScript "update-locks" ''
      set -eu
      mkdir -p locks
      # The lock is put back at exit: Bazel maintains the default variant's own
      # MODULE.bazel.lock, so this app leaves it as it found it. The manifest is
      # different, because regenerating it is the point, and the same trap puts
      # the stash back if a run dies partway and the loop has already moved the
      # live file away.
      cp MODULE.bazel.lock MODULE.bazel.lock.saved
      trap 'mv MODULE.bazel.lock.saved MODULE.bazel.lock${pkgs.lib.optionalString archives ''

        [ -f flazel-archives.json.default ] \
          && mv flazel-archives.json.default flazel-archives.json || true''}' EXIT
      ${pkgs.lib.optionalString archives ''
        # The default variant has no locks/ counterpart, so the loop below never
        # visits it and nothing else regenerates its manifest. It runs first,
        # while MODULE.bazel.lock is still the project's own, and is stashed
        # because each iteration overwrites flazel-archives.json and moves it.
        nix develop --command sh -ec '
          bazel shutdown
          trap "bazel shutdown" EXIT
          flazel-lock-archives
        '
        cp flazel-archives.json flazel-archives.json.default
      ''}
      ${pkgs.lib.concatMapStrings (shell: ''
        # Bazel rewrites the lockfile in its own format; the default one stays
        # in place because dev shells evaluate it. A server left running
        # rewrites it again when another version's client stops it.
        nix develop .#${shell} --command sh -ec '
          bazel shutdown
          trap "bazel shutdown" EXIT
          cp MODULE.bazel.lock.saved MODULE.bazel.lock
          bazel mod deps --lockfile_mode=update >/dev/null
          ${pkgs.lib.optionalString archives "flazel-lock-archives"}
        '
        ${pkgs.lib.optionalString archives "mv flazel-archives.json locks/${shell}.archives.json"}
        mv MODULE.bazel.lock locks/${shell}.lock
      '') shells}
    ''
  );
}
