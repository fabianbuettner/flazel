"""Module extension that declares the vendored crate repositories.

rules_rust's vendoring expects crate_repositories() to be called from a WORKSPACE
file, but flazel builds pure-bzlmod (--noenable_workspace). So invoke it from a
module extension instead: it creates the @crate_vendor* spoke repos from the
committed defs in 3rdparty/crates, with no splice or network at build time.
"""

load("//3rdparty/crates:crates.bzl", "crate_repositories")

def _crates_impl(_module_ctx):
    crate_repositories()

crates = module_extension(implementation = _crates_impl)
