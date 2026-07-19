// https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2014/n4024.pdf
pub const Coroutine = @This();

threadlocal var active_frame: ?*Coroutine = null;

const Status = enum(u8) {
    in_progress,
    done,
    errored,
};

/// The previous SP.
caller_sp: *align(raw_alignment) anyopaque,
/// The current SP.
current_sp: *align(raw_alignment) anyopaque,
/// Stack Info
stack_mem: []align(raw_alignment) u8,
/// Is the Coroutine Frame done?
status: Status = .in_progress,

pub const Stack = enum(usize) {
    @"2KiB" = 2 * unit,
    @"4KiB" = 4 * unit,
    @"8KiB" = 8 * unit,
    @"16KiB" = 16 * unit,
    @"32KiB" = 32 * unit,
    @"64KiB" = 64 * unit,
    @"128KiB" = 128 * unit,
    @"256KiB" = 256 * unit,
    @"512KiB" = 512 * unit,
    @"1MiB" = 1 * unit * unit,
    @"2MiB" = 2 * unit * unit,
    @"4MiB" = 4 * unit * unit,
    /// linux OS thread default
    max = max_thread_stack * unit * unit,
    _,

    /// Bytes
    const unit = 1024;
    /// 8 MiB
    const max_thread_stack = 8;

    /// 64KB: Generally resonable number, for simple callbacks, no recursion,
    /// small locals, minor compute work, shallow call stacks.
    pub const mean: Stack = if (is_unix) .@"64KiB" else .KiB(512 + unit);

    /// 1MB: deep call chains, JSON parsers, recursive algorithms
    pub const large: Stack = if (is_unix) .@"1MiB" else .MiB(3);

    /// This is a best effort guess and will be updated
    /// consistently to match most real world usage
    pub const auto: Stack = switch (builtin.mode) {
        .Debug => if (is_unix) .@"256KiB" else .@"2MiB",
        .ReleaseSafe => if (is_unix) .@"128KiB" else .@"1MiB",
        .ReleaseFast => if (is_unix) .@"32KiB" else .@"256KiB",
        .ReleaseSmall => if (is_unix) .@"8KiB" else .@"126KiB",
    };

    fn Usize(size: Stack) usize {
        debug.assert(@intFromEnum(size) <= @intFromEnum(Stack.max));
        return @intFromEnum(size);
    }

    pub fn MiB(size: usize) Stack {
        debug.assert(size < max_thread_stack);
        return @enumFromInt(size * unit * unit);
    }

    pub fn KiB(size: usize) Stack {
        debug.assert(size < max_thread_stack * unit);
        return @enumFromInt(size * unit);
    }
};

fn stackUsed(frame: *Coroutine) usize {
    if (builtin.mode != .Debug) @compileError("only available in Debug mode");
    // Debug mode fills freed/unused memory with 0xAA
    const canary_byte: u8 = 0xAA;
    // Stack grows downward — scan from bottom for the first non-0xAA byte
    const stack = frame.stack_mem;
    // We look for the first byte that is NOT our canary.
    const unused = mem.findNone(u8, stack, &.{
        canary_byte,
    }).?;
    return (stack.len - unused) * @sizeOf(u8);
}

pub fn init(
    allocator: mem.Allocator,
    comptime coroutine_fn: anytype,
    args: anytype,
    stack_size: ?Stack,
) *Coroutine {
    // Allocate Frame Stack with ABI alignment
    const stack: []align(raw_alignment) u8 = allocator.alignedAlloc(u8, Frame.alignment, size: {
        const size = if (stack_size) |stack| stack.Usize() else Stack.auto.Usize();
        // stack_size should be aligned to `Hardware.alignment`
        debug.assert(Frame.alignment.check(size));
        break :size size;
    }) catch @panic("OOM");

    const stack_base = @intFromPtr(stack.ptr);
    const stack_top = @intFromPtr(stack.ptr + stack.len);

    // space for the frame pointer
    const frame_ptr = Frame.alignment.backward(
        stack_top - @sizeOf(Coroutine),
    );
    debug.assert(frame_ptr > stack_base);

    const frame: *Coroutine = @ptrFromInt(frame_ptr);

    const Args = @TypeOf(args);
    // space for the args pointer
    const args_ptr = Frame.alignment.backward(
        frame_ptr - @sizeOf(Args),
    );
    debug.assert(args_ptr > stack_base);

    const arg_ptr: *Args = @ptrFromInt(args_ptr);
    arg_ptr.* = args;

    // setup space for the `Hardware.stack_count` of callee-saved registers
    const register_ptr = Frame.alignment.backward(
        args_ptr - (@sizeOf(usize) * Frame.stack_count),
    );
    debug.assert(register_ptr > stack_base);

    // address space for the callee-saved registers
    const register_entries: []RegisterFn = @as([*]RegisterFn, @ptrFromInt(
        register_ptr,
    ))[0..Frame.stack_count];

    // A frame pointer of 0x0 denotes the root of the stack for the DWARF unwinder
    // so it knows where to stop unwinding.
    register_entries[Frame.frame_ptr] = @ptrFromInt(0x0);

    // return address/instruction pointer we jump to for the execution of fiber's
    // entry point function after returning from `tardy_swap_frame`
    register_entries[Frame.entry] = EntryFn(coroutine_fn, args);

    frame.* = .{
        .caller_sp = undefined,
        .current_sp = @ptrFromInt(register_ptr),
        .stack_mem = stack,
    };

    return frame;
}

pub fn deinit(self: *Coroutine, allocator: mem.Allocator) void {
    allocator.free(self.stack_mem);
}

/// This runs/continues a Coroutine Frame.
pub fn proceed(frame: *Coroutine) void {
    const old_frame = active_frame;
    debug.assert(old_frame != frame);
    active_frame = frame;
    defer active_frame = old_frame;

    Frame.swap_frame(
        &frame.caller_sp,
        &frame.current_sp,
    );
}

/// This yields/pauses a Frame.
pub fn yield() void {
    const current = active_frame.?;
    Frame.swap_frame(
        &current.current_sp,
        &current.caller_sp,
    );
}

const RegisterFn = *allowzero const fn () callconv(.c) noreturn;
fn EntryFn(comptime coroutine_fn: anytype, args: anytype) RegisterFn {
    const Args = @TypeOf(args);
    const Fn = struct {
        fn inner() callconv(.c) noreturn {
            const frame_ptr: *Coroutine = active_frame.?;

            const args_addr = Frame.alignment.backward(
                @intFromPtr(frame_ptr) - @sizeOf(Args),
            );
            const args_ptr: *Args = @ptrFromInt(args_addr);

            @call(.auto, coroutine_fn, args_ptr.*) catch |e| {
                log.warn("frame failed | {any}", .{e});
                frame_ptr.status = .errored;
                Coroutine.yield();
                unreachable;
            };

            if (builtin.mode == .Debug) {
                log.debug("Coroutine \nfn: `* const {any}`\nUsed {Bi} / {Bi} bytes of stack", .{
                    @TypeOf(coroutine_fn), frame_ptr.stackUsed(), frame_ptr.stack_mem.len,
                });
            }

            // When our coroutine is done running, just yield.
            frame_ptr.status = .done;
            Coroutine.yield();
            unreachable;
        }
    };
    return Fn.inner;
}

const is_unix = builtin.os.tag != .windows;

const log = std.log.scoped(.@"tardy/Coroutine");

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const builtin = @import("builtin");

const context_switch = @import("coroutine/context_switch.zig");
const raw_alignment = context_switch.raw_alignment;
const Frame = context_switch.Frame;
