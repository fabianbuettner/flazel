"""Writes the values of compiler flags, space-separated in the order listed."""

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    values = [flag[config_common.FeatureFlagInfo].value for flag in ctx.attr.flags]
    ctx.actions.write(out, " ".join(values) + "\n")
    return [DefaultInfo(files = depset([out]))]

compiler_flags = rule(
    implementation = _impl,
    attrs = {"flags": attr.label_list(mandatory = True, providers = [config_common.FeatureFlagInfo])},
)
