const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");

const log = std.log.scoped(.@"tardy/frame");

const Hardware = switch (builtin.cpu.arch) {
    .x86_64 => switch (builtin.os.tag) {
        .windows => x64Windows,
        else => x64SysV,
    },
    .aarch64 => aarch64General,
    else => @compileError("Architecture not currently supported!"),
};

const FrameEntryFn = *const fn () callconv(.c) noreturn;
fn EntryFn(args: anytype, comptime func: anytype) FrameEntryFn {
    const Args = @TypeOf(args);
    return struct {
        fn inner() callconv(.c) noreturn {
            const frame = active_frame.?;

            const args_ptr: *Args = @ptrFromInt(@intFromPtr(frame) - @sizeOf(Args));
            @call(.auto, func, args_ptr.*) catch |e| {
                log.warn("frame failed | {any}", .{e});
                frame.status = .errored;
                Frame.yield();
                unreachable;
            };

            // When our func is done running, just yield.
            frame.status = .done;
            Frame.yield();
            unreachable;
        }
    }.inner;
}

threadlocal var active_frame: ?*Frame = null;

pub const Frame = struct {
    const Status = enum(u8) {
        in_progress,
        done,
        errored,
    };

    /// The previous SP.
    caller_sp: *align(Hardware.alignment.toByteUnits()) anyopaque,
    /// The current SP.
    current_sp: *align(Hardware.alignment.toByteUnits()) anyopaque,
    /// Stack Info
    stack_mem: []align(Hardware.alignment.toByteUnits()) u8,
    /// Is the Frame done?
    status: Status = .in_progress,

    pub fn init(
        allocator: std.mem.Allocator,
        stack_size: usize,
        args: anytype,
        comptime func: anytype,
    ) !*Frame {
        // TODO: assert minimum stack size
        // Allocate Fiber/Frame Stack with abi alignment
        const stack = try allocator.alignedAlloc(
            u8,
            Hardware.alignment,
            // in debug mode, SafeAllocator is used by default which requires some extra
            // bookkeeping space for stack trace capturing
            if (builtin.mode == .Debug) stack_size * 2 else stack_size,
        );
        errdefer allocator.free(stack);

        const stack_base = @intFromPtr(stack.ptr);
        const stack_top = @intFromPtr(stack.ptr + stack.len);

        // space for the frame
        var stack_ptr = Hardware.alignment.backward(
            stack_top - @sizeOf(Frame),
        );
        if (stack_ptr < stack_base) return error.StackTooSmall;
        const frame: *Frame = @ptrFromInt(stack_ptr);

        const Args = @TypeOf(args);
        // space for the args
        stack_ptr -= @sizeOf(Args);
        const arg_ptr: *Args = @ptrFromInt(stack_ptr);
        arg_ptr.* = args;

        // setup space for the `Hardware.stack_count` of callee-saved registers
        stack_ptr = Hardware.alignment.backward(
            stack_ptr - @sizeOf(usize) * Hardware.stack_count,
        );
        if (stack_ptr < stack_base) return error.StackTooSmall;

        debug.assert(Hardware.alignment.check(stack_ptr));

        // address space for the callee-saved registers
        const register_entries: []FrameEntryFn = @as([*]FrameEntryFn, @ptrFromInt(stack_ptr))[0..Hardware.stack_count];
        // return address/instruction pointer we jump to for the execution of fiber's
        // entry point function after returning from `tardy_swap_frame`
        register_entries[Hardware.entry] = EntryFn(args, func);

        frame.* = .{
            .caller_sp = undefined,
            .current_sp = @ptrFromInt(stack_ptr),
            .stack_mem = stack,
        };

        return frame;
    }

    pub fn deinit(self: *const Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.stack_mem);
    }

    /// This runs/continues a Frame.
    pub fn proceed(frame: *Frame) void {
        const old_frame = active_frame;
        debug.assert(old_frame != frame);
        active_frame = frame;
        defer active_frame = old_frame;

        Hardware.tardy_swap_frame(&frame.caller_sp, &frame.current_sp);
    }

    /// This yields/pauses a Frame.
    pub fn yield() void {
        const current = active_frame.?;
        Hardware.tardy_swap_frame(&current.current_sp, &current.caller_sp);
    }
};

const x64SysV = struct {
    pub const stack_count = 7;
    pub const entry = stack_count - 1;
    pub const alignment: std.mem.Alignment = .@"16";

    extern fn tardy_swap_frame(
        noalias **align(alignment.toByteUnits()) anyopaque,
        noalias **align(alignment.toByteUnits()) anyopaque,
    ) callconv(.c) void;

    comptime {
        asm (@embedFile("asm/x86_64_sysv.asm"));
    }
};

const x64Windows = struct {
    pub const stack_count = 31;
    pub const entry = stack_count - 1;
    pub const alignment: std.mem.Alignment = .@"16";

    extern fn tardy_swap_frame(
        noalias **align(alignment.toByteUnits()) anyopaque,
        noalias **align(alignment.toByteUnits()) anyopaque,
    ) callconv(.c) void;

    comptime {
        asm (@embedFile("asm/x86_64_win.asm"));
    }
};

const aarch64General = struct {
    pub const stack_count = 20;
    pub const entry = 0;
    pub const alignment: std.mem.Alignment = .@"16";

    extern fn tardy_swap_frame(
        noalias **align(alignment.toByteUnits()) anyopaque,
        noalias **align(alignment.toByteUnits()) anyopaque,
    ) callconv(.c) void;

    comptime {
        // TODO: move assembly into `tardy_swap_frame` definition
        asm (@embedFile("asm/aarch64_gen.asm"));
    }
};
