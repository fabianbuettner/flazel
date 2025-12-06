# Build System Architecture

This project implements a hybrid build system combining **Nix flakes** for dependency management and environment provisioning with **Bazel** for incremental compilation. This architecture addresses fundamental limitations inherent to using either tool in isolation.

## Problem Statement

Traditional build systems face a tension between two goals:

1. **Reproducibility** – Guaranteeing identical outputs across machines and time
2. **Performance** – Minimizing rebuild times during iterative development

Nix excels at (1) but treats builds as atomic units, sacrificing incrementality. Bazel excels at (2) but delegates toolchain management to the user, often resulting in environment-dependent builds.

## Solution: Layered Responsibilities

The **flazel** approach assigns each tool to its strength:

| Layer | Tool | Responsibility |
|-------|------|----------------|
| Environment | Nix | Toolchain provisioning, dependency resolution, hermeticity |
| Compilation | Bazel | Dependency graph analysis, incremental builds, caching |

**Nix provides:**
- Pinned compiler toolchain (GCC, binutils, libc)
- External libraries (boost, SDL2) as reproducible derivations
- Isolated build environment independent of host system

**Bazel provides:**
- Fine-grained dependency tracking at the file level
- Content-addressed caching with cache key invalidation
- Parallel execution with correct incrementality

## Implementation

```nix
# flake.nix defines the complete build environment
flazel.lib.cc.mkConfig {
  inherit pkgs;
  gcc = pkgs.gcc15;
  nixpkgsLibs = {
    boost = pkgs.boost;
    sdl2 = pkgs.SDL2;
  };
}
```

The configuration flows to both entry points:
- `nix develop` – Interactive development shell
- `nix build` – Reproducible release artifact

Both use identical toolchains, eliminating environment drift between development and CI.

## Properties

**Hermeticity**
Builds depend only on declared inputs. No implicit system dependencies. The Nix store provides complete isolation.

**Reproducibility**
`flake.lock` pins nixpkgs; `MODULE.bazel.lock` pins Bazel dependencies. Given identical inputs, builds produce identical outputs.

**Incrementality**
Bazel tracks dependencies at file granularity. Modification to a single source file triggers recompilation of only affected targets.

**Offline capability**
Bazel Central Registry modules are cached in the Nix store. After initial fetch, builds require no network access.

**Portability**
The only host requirement is a Nix installation. All other dependencies are provisioned automatically.

## Build Commands

```bash
# Development workflow
nix develop              # Enter hermetic shell
bazel build //...        # Incremental build
bazel test //...         # Run tests

# Release workflow
nix build                # Produce reproducible artifact
```

## Trade-offs

This approach introduces complexity:
- Two lockfiles to maintain (`flake.lock`, `MODULE.bazel.lock`)
- Custom integration layer (flazel) between Nix and Bazel
- Higher initial setup cost compared to single-tool solutions

These costs are justified for projects requiring both strict reproducibility and fast iteration cycles. For simpler projects, a single build system may be more appropriate.

## References

- [Nix Flakes](https://nixos.wiki/wiki/Flakes) – Hermetic, reproducible package management
- [Bazel](https://bazel.build/) – Scalable, incremental build system

