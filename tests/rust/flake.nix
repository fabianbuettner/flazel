{
  description = "flazel Rust vertical integration test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flazel = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      flazel,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        ccCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
        };

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
      in
      {
        devShells.default = flazel.lib.rust.mkDevShell {
          inherit pkgs caches;
          flazelPath = flazel.outPath;
          toolchains = {
            default = rustCfg;
          };
          ccToolchains = {
            default = ccCfg;
          };
        };
      }
    );
}
