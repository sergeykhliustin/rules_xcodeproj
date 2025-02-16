"""Implementation of the `xcodeproj_runner` rule."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":providers.bzl", "XcodeProjRunnerOutputInfo")

def _get_xcode_product_version(*, xcode_config):
    raw_version = str(xcode_config.xcode_version())
    if not raw_version:
        fail("""\
`xcode_config.xcode_version` was not set. This is a bazel bug. Try again.
""")

    version_components = raw_version.split(".")
    if len(version_components) < 4:
        # This will result in analysis cache misses, but it's better than
        # failing
        return raw_version

    return version_components[3]

def _process_extra_flags(*, attr, content, setting, config, config_suffix):
    extra_flags = getattr(attr, setting)[BuildSettingInfo].value
    if extra_flags:
        content.append(
            "build:{}{} {}".format(config, config_suffix, extra_flags),
        )

def _write_xcodeproj_bazelrc(name, actions, config, template):
    output = actions.declare_file("{}.bazelrc".format(name))

    if config != "rules_xcodeproj":
        project_configs = """
# Set `--verbose_failures` on `info` as the closest to a "no-op" config as
# possible, until https://github.com/bazelbuild/bazel/issues/12844 is fixed
info:{config} --verbose_failures

# Inherit from base configs
build:{config}_generator --config=rules_xcodeproj_generator
build:{config}_generator --config={config}
build:{config}_indexbuild --config=rules_xcodeproj_indexbuild
build:{config}_indexbuild --config={config}
build:{config}_swiftuipreviews --config=rules_xcodeproj_swiftuipreviews
build:{config}_swiftuipreviews --config={config}
build:{config}_asan --config=rules_xcodeproj_asan
build:{config}_asan --config={config}
build:{config}_tsan --config=rules_xcodeproj_tsan
build:{config}_tsan --config={config}
build:{config}_ubsan --config=rules_xcodeproj_ubsan
build:{config}_ubsan --config={config}

# Private implementation detail. Don't adjust this config, adjust
# `{config}` instead.
build:_{config}_build --config=_rules_xcodeproj_build
build:_{config}_build --config={config}
""".format(config = config)
    else:
        project_configs = ""

    actions.expand_template(
        template = template,
        output = output,
        substitutions = {
            "%project_configs%": project_configs,
        },
    )

    return output

def _write_extra_flags_bazelrc(name, actions, attr, config):
    output = actions.declare_file("{}-extra-flags.bazelrc".format(name))

    content = []

    _process_extra_flags(
        attr = attr,
        content = content,
        setting = "_extra_common_flags",
        config = config,
        config_suffix = "",
    )
    _process_extra_flags(
        attr = attr,
        content = content,
        setting = "_extra_indexbuild_flags",
        config = config,
        config_suffix = "_indexbuild",
    )
    _process_extra_flags(
        attr = attr,
        content = content,
        setting = "_extra_swiftuipreviews_flags",
        config = config,
        config_suffix = "_swiftuipreviews",
    )

    # Trailing newline
    content.append("")

    actions.write(
        output = output,
        content = "\n".join(content),
    )

    return output

def _write_runner(
        *,
        name,
        actions,
        bazel_path,
        config,
        extra_flags_bazelrc,
        extra_generator_flags,
        generator_label,
        is_fixture,
        project_name,
        runner_label,
        template,
        xcode_version,
        xcodeproj_bazelrc):
    output = actions.declare_file("{}-runner.sh".format(name))

    is_bazel_6 = hasattr(apple_common, "link_multi_arch_static_library")

    actions.expand_template(
        template = template,
        output = output,
        is_executable = True,
        substitutions = {
            "%bazel_path%": bazel_path,
            "%config%": config,
            "%extra_flags_bazelrc%": extra_flags_bazelrc.short_path,
            "%extra_generator_flags%": extra_generator_flags,
            "%generator_label%": generator_label,
            "%is_bazel_6%": "1" if is_bazel_6 else "0",
            "%is_fixture%": "1" if is_fixture else "0",
            "%project_name%": project_name,
            "%runner_label%": runner_label,
            "%xcode_version%": xcode_version,
            "%xcodeproj_bazelrc%": xcodeproj_bazelrc.short_path,
        },
    )

    return output

def _xcodeproj_runner_impl(ctx):
    config = ctx.attr.config
    project_name = ctx.attr.project_name

    xcode_version = _get_xcode_product_version(
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
    )

    xcodeproj_bazelrc = _write_xcodeproj_bazelrc(
        name = ctx.attr.name,
        actions = ctx.actions,
        config = config,
        template = ctx.file._bazelrc_template,
    )
    extra_flags_bazelrc = _write_extra_flags_bazelrc(
        name = ctx.attr.name,
        actions = ctx.actions,
        attr = ctx.attr,
        config = config,
    )

    runner = _write_runner(
        name = ctx.attr.name,
        actions = ctx.actions,
        bazel_path = ctx.attr.bazel_path,
        config = config,
        extra_flags_bazelrc = extra_flags_bazelrc,
        extra_generator_flags = (
            ctx.attr._extra_generator_flags[BuildSettingInfo].value
        ),
        generator_label = ctx.attr.xcodeproj_target,
        is_fixture = ctx.attr.is_fixture,
        project_name = project_name,
        runner_label = str(ctx.label),
        template = ctx.file._runner_template,
        xcode_version = xcode_version,
        xcodeproj_bazelrc = xcodeproj_bazelrc,
    )

    return [
        DefaultInfo(
            executable = runner,
            runfiles = ctx.runfiles(
                files = [
                    extra_flags_bazelrc,
                    xcodeproj_bazelrc,
                ],
            ),
        ),
        XcodeProjRunnerOutputInfo(
            project_name = project_name,
            runner = runner,
        ),
    ]

xcodeproj_runner = rule(
    implementation = _xcodeproj_runner_impl,
    attrs = {
        "bazel_path": attr.string(
            mandatory = True,
        ),
        "config": attr.string(
            mandatory = True,
        ),
        "is_fixture": attr.bool(
            mandatory = True,
        ),
        "project_name": attr.string(
            mandatory = True,
        ),
        "xcodeproj_target": attr.string(
            mandatory = True,
        ),
        "_bazelrc_template": attr.label(
            allow_single_file = True,
            default = Label("//xcodeproj/internal:xcodeproj.template.bazelrc"),
        ),
        "_extra_common_flags": attr.label(
            default = Label("//xcodeproj:extra_common_flags"),
            providers = [BuildSettingInfo],
        ),
        "_extra_generator_flags": attr.label(
            default = Label("//xcodeproj:extra_generator_flags"),
            providers = [BuildSettingInfo],
        ),
        "_extra_indexbuild_flags": attr.label(
            default = Label("//xcodeproj:extra_indexbuild_flags"),
            providers = [BuildSettingInfo],
        ),
        "_extra_swiftuipreviews_flags": attr.label(
            default = Label("//xcodeproj:extra_swiftuipreviews_flags"),
            providers = [BuildSettingInfo],
        ),
        "_runner_template": attr.label(
            allow_single_file = True,
            default = Label("//xcodeproj/internal:runner.template.sh"),
        ),
        "_xcode_config": attr.label(
            default = configuration_field(
                name = "xcode_config_label",
                fragment = "apple",
            ),
        ),
    },
    executable = True,
)
