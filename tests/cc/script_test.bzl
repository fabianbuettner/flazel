"""A test with no C++ in it: what toolchain resolution gives every test rule."""

def _impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [DefaultInfo(executable = script)]

script_test = rule(implementation = _impl, test = True)
