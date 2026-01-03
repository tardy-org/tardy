const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const AsyncKind = @import("src/aio/lib.zig").AsyncKind;

const zig_version = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
comptime {
    // Compare versions while allowing different pre/patch metadata.
    const zig_version_eq = zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor and
        zig_version.patch == builtin.zig_version.patch;
    if (!zig_version_eq) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: expected {f}, found {f}",
            .{ zig_version, builtin.zig_version },
        ));
    }
}

const Example = enum {
    none,
    all,
    basic,
    cat,
    channel,
    echo,
    http,
    rmdir,
    shove,
    stat,
    stream,

    fn toString(ex: Example) []const u8 {
        const ex_string = switch (ex) {
            .basic => "basic",
            .cat => "cat",
            .channel => "channel",
            .echo => "echo",
            .http => "http",
            .rmdir => "rmdir",
            .shove => "shove",
            .stat => "stat",
            .stream => "stream",

            else => "",
        };

        return ex_string;
    }
};
pub fn build(b: *std.Build) void {

    // Top-level steps you can invoke on the command line.
    const build_steps = .{
        .run = b.step("run", "Run a Tardy Program/Example"),
        .static = b.step("static", "Build tardy as a static lib"),
        .@"test" = b.step("test", "Run all tests"),
        .test_unit = b.step("test_unit", "Run general unit tests"),
        .test_fmt = b.step("test_fmt", "Run formmatter tests"),
        .test_e2e = b.step("test_e2e", "Run e2e tests"),
    };

    // Build options passed with `-D` flags.
    const build_options = .{
        .example = b.option(Example, "example", "example name") orelse .none,
        .async_backend = b.option(AsyncKind, "async", "async backend to use") orelse .auto,
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // create a public tardy module
    const tardy = b.addModule("tardy", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // build and run examples
    // usage: zig [build/build run] -Dexample[example_name]
    build_examples(b, .{
        .run = build_steps.run,
        .install = b.getInstallStep(),
    }, .{
        .tardy_mod = tardy,
        .example = build_options.example,
        .optimize = optimize,
        .target = target,
    });

    // build tardy as a static lib
    // usage: zig build static
    build_static_lib(b, .{
        .static = build_steps.static,
    }, .{
        .tardy_mod = tardy,
        .optimize = optimize,
        .target = target,
    });

    // build and run tests
    // usage: refer to function declaration
    build_test(b, .{
        .test_unit = build_steps.test_unit,
        .test_fmt = build_steps.test_fmt,
        .@"test" = build_steps.@"test",
    }, .{
        .tardy_mod = tardy,
        .optimize = optimize,
        .target = target,
    });

    // build and run e2e test
    // usage: zig build test_e2e -Dasync=[async_backend] -- [u64 num]
    build_test_e2e(b, .{
        .test_e2e = build_steps.test_e2e,
    }, .{
        .async_backend = build_options.async_backend,
        .tardy_mod = tardy,
        .optimize = optimize,
        .target = target,
    });
}

// used for building and running examples
fn build_examples(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: struct {
        tardy_mod: *std.Build.Module,
        example: Example,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    if (options.example == .none) {
        return;
    }

    // build/run specific example
    if (options.example != .none and options.example != .all) {
        build_example_exe(
            b,
            .{
                .run = steps.run,
                .install = steps.install,
            },
            .{
                .tardy_mod = options.tardy_mod,
                .example = options.example,
                .all_examples = false,
                .optimize = options.optimize,
                .target = options.target,
            },
        );

        return;
    }

    // build .all example
    // run wont work for .all example
    if (options.example == .all) {
        std.log.info("zig build run -Dexample=all will only build examples and will not run them", .{});

        inline for (std.meta.fields(Example)) |f| {
            // convert captured field value to field enum
            const field = @as(Example, @enumFromInt(f.value));

            // skip .none and .all for building step
            if (field == .none or field == .all) {
                continue;
            }

            build_example_exe(
                b,
                .{
                    .run = steps.run,
                    .install = steps.install,
                },
                .{
                    .tardy_mod = options.tardy_mod,
                    .example = field,
                    .all_examples = true,
                    .optimize = options.optimize,
                    .target = options.target,
                },
            );
        }
        return;
    }
}

fn build_example_module(
    b: *std.Build,
    options: struct {
        tardy_mod: *std.Build.Module,
        example: Example,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) *std.Build.Module {
    assert(options.example != .none);
    assert(options.example != .all);

    // create a private example module
    const example_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{options.example.toString()})),
        .target = options.target,
        .optimize = options.optimize,
    });

    example_mod.addImport("tardy", options.tardy_mod);

    // need libc for windows sockets
    if (options.target.result.os.tag == .windows) {
        example_mod.link_libc = true;
    }

    return example_mod;
}

// build/run a specific example
fn build_example_exe(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: struct {
        tardy_mod: *std.Build.Module,
        example: Example,
        all_examples: bool,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    assert(options.example != .none);
    assert(options.example != .all);

    const example_mod = build_example_module(b, .{
        .tardy_mod = options.tardy_mod,
        .example = options.example,
        .optimize = options.optimize,
        .target = options.target,
    });

    const example_exe = b.addExecutable(.{
        .name = options.example.toString(),
        .root_module = example_mod,
        // without llvm leads to error: undefined symbol: tardy_swap_frame
        .use_llvm = true,
    });

    const install_artifact = b.addInstallArtifact(example_exe, .{});

    // depend on build/install step
    steps.install.dependOn(&install_artifact.step);

    // Should not run all examples at the same time
    if (options.all_examples) {
        return;
    }

    // depend on run step
    const run_artifact = b.addRunArtifact(example_exe);
    run_artifact.step.dependOn(&install_artifact.step);

    // pass args to examples (.ie cat, rmdir, shove, stat)
    if (b.args) |args| {
        run_artifact.addArgs(args);
    }

    steps.run.dependOn(&install_artifact.step);
    steps.run.dependOn(&run_artifact.step);
}

fn build_static_lib(
    b: *std.Build,
    steps: struct {
        static: *std.Build.Step,
    },
    options: struct {
        tardy_mod: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tardy",
        .root_module = options.tardy_mod,
    });

    // need libc for windows sockets
    if (options.target.result.os.tag == .windows) {
        static_lib.linkLibC();
    }

    // depend on static step
    const install_artifact = b.addInstallArtifact(static_lib, .{});
    steps.static.dependOn(&install_artifact.step);
}

fn build_test(
    b: *std.Build,
    steps: struct {
        test_unit: *std.Build.Step,
        test_fmt: *std.Build.Step,
        @"test": *std.Build.Step,
    },
    options: struct {
        tardy_mod: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    // Run general unit tests
    // usage: zig build test_unit
    const unit_tests = b.addTest(.{
        .name = "general unit tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/tests.zig"),
            .optimize = options.optimize,
            .target = options.target,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.step.dependOn(&unit_tests.step);

    steps.test_unit.dependOn(&run_unit_tests.step);

    // Check formatting
    // usage: zig build fmt
    const run_fmt = b.addFmt(.{ .paths = &.{"."}, .check = true });
    steps.test_fmt.dependOn(&run_fmt.step);

    // Run all tests
    // usage: zig build test
    steps.@"test".dependOn(&run_unit_tests.step);
    steps.@"test".dependOn(steps.test_fmt);
}

fn build_test_e2e(
    b: *std.Build,
    steps: struct {
        test_e2e: *std.Build.Step,
    },
    options: struct {
        async_backend: AsyncKind,
        tardy_mod: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    // create a private example module
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = false,
    });

    e2e_mod.addImport("tardy", options.tardy_mod);

    // need libc for windows sockets
    if (options.target.result.os.tag == .windows) {
        e2e_mod.link_libc = true;
    }

    // add needed options
    const test_options = b.addOptions();
    test_options.addOption(AsyncKind, "async_option", options.async_backend);

    e2e_mod.addOptions("options", test_options);

    // create executable
    const exe = b.addExecutable(.{
        .name = "e2e",
        .root_module = e2e_mod,
        // without llvm leads to error: undefined symbol: tardy_swap_frame
        .use_llvm = true,
    });

    // build/install e2e test
    const install_artifact = b.addInstallArtifact(exe, .{});
    steps.test_e2e.dependOn(&install_artifact.step);

    // run e2e test
    const run_artifact = b.addRunArtifact(exe);
    run_artifact.step.dependOn(&install_artifact.step);

    // pass a u64 as an arg
    if (b.args) |args| run_artifact.addArgs(args);

    steps.test_e2e.dependOn(&install_artifact.step);
    steps.test_e2e.dependOn(&run_artifact.step);
}
