"""Stub CC toolchain config for cross-compilation targets."""

def _stub_cc_config_impl(ctx):
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "stub-cross",
        host_system_name = "local",
        target_system_name = "stub",
        target_cpu = "stub",
        target_libc = "stub",
        compiler = "stub",
        abi_version = "stub",
        abi_libc_version = "stub",
        tool_paths = [],
    )

stub_cc_config = rule(
    implementation = _stub_cc_config_impl,
    provides = [CcToolchainConfigInfo],
)
