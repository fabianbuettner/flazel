# Bazel whose actions find /usr/bin/env in a Linux Nix build sandbox, which
# has no /usr and an unwritable root. Bazel's own sandbox mounts only over
# existing paths, so where /usr/bin/env is missing, Bazel runs in a new root
# holding each entry of the old one plus coreutils' env.
{ pkgs, bazel }:
if !pkgs.stdenv.buildPlatform.isLinux then
  bazel
else
  pkgs.writeShellApplication {
    name = "bazel";
    text = ''
      if [ -e /usr/bin/env ]; then
        exec ${bazel}/bin/bazel "$@"
      fi
      # Binding env into an existing /usr would mount over or create a file in
      # a filesystem that is not ours.
      if [ -e /usr ] || [ -L /usr ]; then
        echo "flazel: /usr exists but has no /usr/bin/env; refusing to add one" >&2
        exit 1
      fi
      binds=()
      shopt -s dotglob nullglob
      for entry in /*; do
        binds+=(--dev-bind "$entry" "$entry")
      done
      # bwrap writes child-pid to the status fd once its namespace exists, and
      # its exit code last, so the reader drains the pipe before judging.
      exec 3> >(
        status=$(${pkgs.coreutils}/bin/cat)
        case $status in
        *child-pid*) ;;
        *) echo "flazel: no /usr/bin/env, and bwrap could not create a user namespace to add one (above)" >&2 ;;
        esac
      )
      exec ${pkgs.bubblewrap}/bin/bwrap --die-with-parent --json-status-fd 3 "''${binds[@]}" \
        --ro-bind ${pkgs.coreutils}/bin/env /usr/bin/env ${bazel}/bin/bazel "$@"
    '';
  }
