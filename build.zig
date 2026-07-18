pub fn build(b: *std.Build) void {
    comptime checkVersion();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // create a public tardy module
    const tardy = b.addModule("tardy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // currently not supported on aarch64
        .error_tracing = target.result.cpu.arch != .aarch64,
        .pic = true,
    });

    const options: BuildOptions = .{
        .async_backend = build_options.async_backend,
        .tardy_mod = tardy,
        .optimize = optimize,
        .target = target,
    };

    // build and run examples
    // usage: zig [build/build run] -Dasync=[async_backend] -Dexample[example_name]
    build_examples(b, .{
        .run = build_steps.run,
        .install = b.getInstallStep(),
    }, .{
        .async_backend = build_options.async_backend,
        .tardy_mod = tardy,
        .example = build_options.example,
        .optimize = optimize,
        .target = target,
        .skip_run_step_steup = undefined,
    });

    // build tardy as a static lib
    // usage: zig build static
    build_static_lib(
        b,
        .{ .static = build_steps.static },
        options,
    );

    // build and run tests
    // usage: refer to function declaration
    build_test(b, .{
        .test_unit = build_steps.test_unit,
        .test_fmt = build_steps.test_fmt,
        .@"test" = build_steps.@"test",
    }, options);

    // build and run e2e test
    // usage: zig build test_e2e -Dasync=[async_backend] -- [u64 num]
    build_test_e2e(
        b,
        .{ .test_e2e = build_steps.test_e2e },
        options,
    );
}

// used for building and running examples
fn build_examples(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: ExampleOptions,
) void {
    // build/run specific example
    switch (options.example) {
        .none => return,
        // build .all example
        // run wont work for .all example
        .all => {
            log.info("zig build run -Dexample=all will only build examples and will not run them", .{});

            inline for (@typeInfo(Example).@"enum".field_values) |value| {
                // convert captured field value to field enum
                const field: Example = @enumFromInt(value);

                // skip .none and .all for building step
                if (field == .none or field == .all) continue;

                build_example_exe(
                    b,
                    .{
                        .run = steps.run,
                        .install = steps.install,
                    },
                    .{
                        .async_backend = options.async_backend,
                        .tardy_mod = options.tardy_mod,
                        .example = field,
                        .optimize = options.optimize,
                        .target = options.target,
                        .skip_run_step_steup = true,
                    },
                );
            }
        },
        else => {
            return build_example_exe(
                b,
                .{
                    .run = steps.run,
                    .install = steps.install,
                },
                .{
                    .async_backend = options.async_backend,
                    .tardy_mod = options.tardy_mod,
                    .example = options.example,
                    .optimize = options.optimize,
                    .target = options.target,
                    .skip_run_step_steup = false,
                },
            );
        },
    }
}

fn build_example_module(
    b: *std.Build,
    options: ExampleOptions,
) *std.Build.Module {
    debug.assert(options.example != .none);
    debug.assert(options.example != .all);

    // create a private example module
    const example_mod = b.createModule(.{
        .root_source_file = b.path(
            b.fmt("examples/{t}/main.zig", .{options.example}),
        ),
        .target = options.target,
        .optimize = options.optimize,
    });

    example_mod.addImport("tardy", options.tardy_mod);

    const example_options = b.addOptions();
    example_options.addOption(
        AsyncKind,
        "async_backend",
        options.async_backend,
    );
    example_mod.addOptions("options", example_options);

    return example_mod;
}

// build/run a specific example
fn build_example_exe(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: ExampleOptions,
) void {
    debug.assert(options.example != .none);
    debug.assert(options.example != .all);

    const example_mod = build_example_module(b, options);

    // windows: errors with `unknow size: 0xx(%%rsp)` without llvm
    // aarch64: use_new_linker panics and codegen deadlocks without llvm
    const use_llvm = (options.target.result.os.tag == .windows) or
        (options.target.result.cpu.arch == .aarch64);
    const example_exe = b.addExecutable(.{
        .name = @tagName(options.example),
        .root_module = example_mod,
        .use_llvm = use_llvm,
    });
    example_exe.use_new_linker = !use_llvm;

    const install_artifact = b.addInstallArtifact(
        example_exe,
        .{},
    );

    // depend on build/install step
    steps.install.dependOn(&install_artifact.step);

    // Should not run all examples at the same time
    if (options.skip_run_step_steup) return;

    const run_artifact = b.addRunArtifact(example_exe);
    run_artifact.step.dependOn(&install_artifact.step);

    // pass args to examples (.ie cat, rmdir, shove, stat)
    run_artifact.addPassthruArgs();

    steps.run.dependOn(&install_artifact.step);
    steps.run.dependOn(&run_artifact.step);
}

fn build_static_lib(
    b: *std.Build,
    steps: struct {
        static: *std.Build.Step,
    },
    options: BuildOptions,
) void {
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tardy",
        .root_module = options.tardy_mod,
    });

    // depend on static step
    const install_artifact = b.addInstallArtifact(
        static_lib,
        .{},
    );
    steps.static.dependOn(&install_artifact.step);
}

fn build_test(
    b: *std.Build,
    steps: struct {
        test_unit: *std.Build.Step,
        test_fmt: *std.Build.Step,
        @"test": *std.Build.Step,
    },
    options: BuildOptions,
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
    const run_fmt = b.addFmt(.{
        .paths = &.{b.path(".")},
        .check = true,
    });
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
    options: BuildOptions,
) void {
    // create a private example module
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = false,
        .imports = &.{
            .{
                .name = "tardy",
                .module = options.tardy_mod,
            },
        },
    });

    // add needed options
    const test_options = b.addOptions();
    test_options.addOption(
        AsyncKind,
        "async_backend",
        options.async_backend,
    );

    e2e_mod.addOptions("options", test_options);

    // windows: errors with `unknow size: 0xx(%%rsp)` without llvm
    // aarch64: use_new_linker panics and codegen deadlocks without llvm
    const use_llvm = (options.target.result.os.tag == .windows) or
        (options.target.result.cpu.arch == .aarch64);
    const exe = b.addExecutable(.{
        .name = "e2e",
        .root_module = e2e_mod,
        .use_llvm = use_llvm,
    });
    exe.use_new_linker = !use_llvm;

    // build/install e2e test
    const install_artifact = b.addInstallArtifact(exe, .{});
    steps.test_e2e.dependOn(&install_artifact.step);

    // run e2e test
    const run_artifact = b.addRunArtifact(exe);
    run_artifact.step.dependOn(&install_artifact.step);

    // pass a u64 as an arg
    run_artifact.addPassthruArgs();

    steps.test_e2e.dependOn(&install_artifact.step);
    steps.test_e2e.dependOn(&run_artifact.step);
}

// ensures the currently in-use zig version is at least the minimum required
fn checkVersion() void {
    const minimum_zig_version: []const u8 = @import("build.zig.zon").minimum_zig_version;
    const supported_version = std.SemanticVersion.parse(
        minimum_zig_version,
    ) catch unreachable;

    const current_version = builtin.zig_version;
    // Compare versions while allowing different pre/patch metadata.
    const order = current_version.order(supported_version);
    switch (order) {
        .lt => {
            const message = std.fmt.comptimePrint(
                \\Your Zig version ({0s}) is less than the
                \\minimum supported by Tardy ({1s}).
                \\
                \\Update your Zig toolchain to `{1s}`
                \\
            , .{ builtin.zig_version_string, minimum_zig_version });
            @compileError(message);
        },
        else => {},
    }
}

const ExampleOptions = struct {
    async_backend: AsyncKind,
    tardy_mod: *std.Build.Module,
    example: Example,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    skip_run_step_steup: bool,
};

const BuildOptions = struct {
    async_backend: AsyncKind,
    tardy_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

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
};

pub const AsyncKind = enum {
    auto,
    io_uring,
    epoll,
    kqueue,
    poll,
};

const log = std.log.scoped(.@"build.zig");

const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");
