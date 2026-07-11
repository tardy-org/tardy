pub fn Tardy(comptime selected_aio: AsyncIO.Kind) type {
    return struct {
        const Self = @This();
        aios: std.ArrayList(inner: {
            const AioImpl = selected_aio.Impl();
            break :inner *AioImpl;
        }),
        // TODO: maybe make this an arena
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        options: Options,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Self {
            const aio_type: AsyncIO.Kind = switch (selected_aio) {
                .auto => AsyncIO.native(),
                else => selected_aio,
            };

            log.info("aio backend: {t}", .{aio_type});

            return .{
                .io = io,
                .allocator = allocator,
                .options = options,
                .aios = try .initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.aios.items) |aio| self.allocator.destroy(aio);
            self.aios.deinit(self.allocator);
        }

        /// This will spawn a new Runtime.
        fn spawn_runtime(self: *Self, id: usize, options: AsyncIO.Options) !Runtime {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var aio: AsyncIO = blk: {
                var io_inner = try self.allocator.create(selected_aio.Impl());
                errdefer self.allocator.destroy(io_inner);

                io_inner.* = try .init(self.allocator, options);
                errdefer io_inner.inner_deinit(self.allocator);

                try self.aios.append(self.allocator, io_inner);
                var aio = io_inner.to_async();

                const completions = try self.allocator.alloc(Completion, self.options.size_aio_reap_max);
                errdefer self.allocator.free(completions);

                aio.attach(completions);
                break :blk aio;
            };
            errdefer aio.deinit(self.allocator, self.io);

            return try .init(self.allocator, self.io, aio, .{
                .id = id,
                .pooling = self.options.pooling,
                .size_tasks_initial = self.options.size_tasks_initial,
                .size_aio_reap_max = self.options.size_aio_reap_max,
            });
        }

        /// This is the entry into all of the runtimes.
        ///
        /// The provided func needs to have a signature of (*Runtime, anytype) !void;
        ///
        /// The provided allocator is meant to just initialize any structures that will exist throughout the lifetime
        /// of the runtime. It happens in an arena and is cleaned up after the runtime terminates.
        pub fn entry(
            self: *Self,
            entry_params: anytype,
            comptime entry_func: *const fn (*Runtime, @TypeOf(entry_params)) anyerror!void,
        ) !void {
            const runtime_count: usize = switch (self.options.threading) {
                .single => 1,
                .multi => |count| count,
                .auto => @max(try std.Thread.getCpuCount() / 2 - 1, 1),
                .all => try std.Thread.getCpuCount(),
            };

            // for post-spawn syncing
            var spawned_count: Atomic(usize) = .init(0);
            const spawning_count = runtime_count - 1;

            var runtime = try self.spawn_runtime(0, .{
                .parent_async = null,
                .pooling = self.options.pooling,
                .size_tasks_initial = self.options.size_tasks_initial,
                .size_aio_reap_max = self.options.size_aio_reap_max,
            });
            defer runtime.deinit();

            assert(runtime_count > 0);
            log.info("thread count: {d}", .{runtime_count});

            var threads: std.ArrayList(std.Thread) = try .initCapacity(
                self.allocator,
                runtime_count -| 1,
            );
            defer {
                log.debug("waiting for the remaining threads to terminate", .{});
                for (threads.items) |thread| thread.join();
                threads.deinit(self.allocator);
            }
            // for in-spawn id assignment
            var spawn_id: Atomic(usize) = .init(1);

            for (0..spawning_count) |_| {
                const current_index = spawn_id.fetchAdd(1, .monotonic);
                const handle: std.Thread = try .spawn(.{}, struct {
                    fn thread_init(
                        tardy: *Self,
                        options: Options,
                        parent: *AsyncIO,
                        entry_parameters: @TypeOf(entry_params),
                        count: *Atomic(usize),
                        total_count: usize,
                        current_id: usize,
                    ) void {
                        var thread_rt = tardy.spawn_runtime(current_id, .{
                            .parent_async = parent,
                            .pooling = options.pooling,
                            .size_tasks_initial = options.size_tasks_initial,
                            .size_aio_reap_max = options.size_aio_reap_max,
                        }) catch |e| {
                            log.err("failed to spawn runtime {d}: {t}", .{ current_id, e });
                            return;
                        };
                        defer thread_rt.deinit();

                        _ = count.fetchAdd(1, .acquire);
                        while (count.load(.acquire) < total_count) {}

                        @call(.auto, entry_func, .{ &thread_rt, entry_parameters }) catch |e| {
                            log.err("{d} - entry error={t}", .{ thread_rt.id, e });
                            thread_rt.stop();
                        };

                        thread_rt.run() catch |e| log.err("{d} - runtime error={t}", .{ thread_rt.id, e });

                        // wait for the rest to stop before cleaning ourselves up.
                        // this is because the runtime is allocate on our stack and others might be checking
                        // our running status or attempting to wake us.
                        _ = count.fetchSub(1, .acquire);
                        while (count.load(.acquire) > 0) tardy.io.sleep(.fromSeconds(1), .awake) catch unreachable;
                    }
                }.thread_init, .{
                    self,
                    self.options,
                    &runtime.aio,
                    entry_params,
                    &spawned_count,
                    spawning_count,
                    current_index,
                });

                threads.appendAssumeCapacity(handle);
            }

            while (spawned_count.load(.acquire) < spawning_count) {}
            log.debug("all runtimes spawned, initalizing...", .{});

            @call(.auto, entry_func, .{
                &runtime,
                entry_params,
            }) catch |e| {
                log.err("0 - entry error={t}", .{e});
                runtime.stop();
            };
            runtime.run() catch |e| log.err("0 - runtime error={t}", .{e});
        }

        /// This spawns in and enters into the runtime
        /// in a new Thread, allowing for more code to
        /// execute even after the runtime spawns.
        pub fn entry_in_new_thread(
            self: *Self,
            entry_params: anytype,
            comptime entry_func: *const fn (
                *Runtime,
                @TypeOf(entry_params),
            ) anyerror!void,
        ) !void {
            const handle: std.Thread = try .spawn(.{}, struct {
                fn entry_in_new_thread(tardy: *Self, ip: @TypeOf(entry_params)) void {
                    tardy.entry(ip, entry_func) catch unreachable;
                }
            }.entry_in_new_thread, .{ self, entry_params });
            handle.detach();
        }
    };
}

const log = std.log.scoped(.tardy);

// Results
pub const TardyThreading = union(enum) {
    single,
    multi: usize,
    all,
    /// Calculated by `@max((cpu_count / 2) - 1, 1)`
    auto,
};

const Options = struct {
    /// Threading that Tardy runtime will use.
    ///
    /// Default = .auto
    threading: TardyThreading = .auto,
    /// Pooling Style
    ///
    /// By default (`.grow`), this means the internal pools
    /// will grow to fit however many tasks/async jobs
    /// you feed it until an OOM condition
    ///
    /// You can also set it to `.static` to lock the
    /// maximum number of tasks and aio jobs.
    ///
    /// Default = .grow
    pooling: PoolKind = .grow,
    /// Number of initial Tasks.
    ///
    /// If our pooling is grow, this will be the upper-limit
    /// before any allocations happen.
    ///
    /// If our pooling is static, this will be the maximum limit.
    ///
    /// Default: 1024
    size_tasks_initial: usize = 1024,
    /// Maximum number of aio completions we can reap
    /// with a single call of reap().
    ///
    /// Default: 1024
    size_aio_reap_max: usize = 1024,
};

const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const builtin = @import("builtin");

pub const AcceptResult = @import("aio/completion.zig").AcceptResult;
pub const ConnectResult = @import("aio/completion.zig").ConnectResult;
pub const RecvResult = @import("aio/completion.zig").RecvResult;
pub const SendResult = @import("aio/completion.zig").SendResult;
pub const OpenFileResult = @import("aio/completion.zig").OpenFileResult;
pub const OpenDirResult = @import("aio/completion.zig").OpenDirResult;
pub const ReadResult = @import("aio/completion.zig").ReadResult;
pub const WriteResult = @import("aio/completion.zig").WriteResult;
pub const StatResult = @import("aio/completion.zig").StatResult;
pub const CreateDirResult = @import("aio/completion.zig").CreateDirResult;
pub const DeleteResult = @import("aio/completion.zig").DeleteResult;
pub const DeleteTreeResult = @import("aio/completion.zig").DeleteTreeResult;
const Completion = @import("aio/completion.zig").Completion;
pub const AsyncIO = @import("aio.zig");
pub const Spsc = @import("channel/spsc.zig").Spsc;
pub const Pool = @import("core/pool.zig").Pool;
pub const PoolKind = @import("core/pool.zig").PoolKind;
pub const Queue = @import("core/queue.zig").Queue;
pub const ZeroCopy = @import("core/zero_copy.zig").ZeroCopy;
/// Cross-platform abstractions.
/// For the `std.posix` interface types.
pub const Cross = @import("cross/lib.zig");
pub const Frame = @import("frame/lib.zig").Frame;
pub const File = @import("fs/lib.zig").File;
pub const Dir = @import("fs/lib.zig").Dir;
pub const Path = @import("fs/lib.zig").Path;
pub const Stat = @import("fs/lib.zig").Stat;
pub const Socket = @import("net/lib.zig").Socket;
pub const Runtime = @import("runtime/lib.zig").Runtime;
pub const Task = @import("runtime/task.zig").Task;
pub const Timer = @import("runtime/timer.zig").Timer;
