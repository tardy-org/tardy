const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");

const log = std.log.scoped(.@"tardy/frame");

// TODO: make Frame a Struct with all this inside it
const Hardware = switch (builtin.cpu.arch) {
    .x86_64 => switch (builtin.os.tag) {
        .windows => x64Windows,
        else => x64SysV,
    },
    .aarch64 => aarch64General,
    else => @compileError("Architecture not currently supported!"),
};

const FrameEntryFn = *allowzero const fn () callconv(.c) noreturn;
fn EntryFn(comptime coroutine_fn: anytype, args: anytype) FrameEntryFn {
    const Args = @TypeOf(args);
    const Fn = struct {
        fn inner() callconv(.c) noreturn {
            const frame_ptr: *Frame = active_frame.?;

            const args_addr = Hardware.alignment.backward(
                @intFromPtr(frame_ptr) - @sizeOf(Args),
            );
            const args_ptr: *Args = @ptrFromInt(args_addr);

            @call(.auto, coroutine_fn, args_ptr.*) catch |e| {
                log.warn("frame failed | {any}", .{e});
                frame_ptr.status = .errored;
                Frame.yield();
                unreachable;
            };

            if (builtin.mode == .Debug) {
                log.info("Coroutine \n`fn * const {any}`\nWith args `{any}`\nUsed {Bi} / {Bi} bytes of stack", .{
                    @TypeOf(coroutine_fn), @TypeOf(args), frame_ptr.stackUsed(), frame_ptr.stack_mem.len,
                });
            }

            // When our coroutine is done running, just yield.
            frame_ptr.status = .done;
            Frame.yield();
            unreachable;
        }
    };
    return Fn.inner;
}

threadlocal var active_frame: ?*Frame = null;

const raw_alignment = Hardware.alignment.toByteUnits();
pub const Frame = struct {
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
    /// Is the Frame done?
    status: Status = .in_progress,

    pub const Stack = enum(usize) {
        @"2KiB" = 2 * unit,
        @"8KiB" = 8 * unit,
        @"16KiB" = 16 * unit,
        @"32KiB" = 32 * unit,
        @"64KiB" = 64 * unit,
        @"128KiB" = 128 * unit,
        @"256KiB" = 256 * unit,
        @"1MiB" = 1 * unit * unit,
        /// linux OS thread default
        max_thread_stack = 8 * unit * unit,
        _,

        /// 64KB: Generally resonable number, for simple callbacks, no recursion,
        /// small locals, minor compute work, shallow call stacks.
        pub const std: Stack = .@"64KiB";
        /// 1MB: deep call chains, JSON parsers, recursive algorithms
        pub const large: Stack = .@"1MiB";

        /// This is a best effort guess
        pub const auto: Stack = switch (builtin.mode) {
            // 256KB: default — covers most async I/O handlers
            .Debug => .@"256KiB",
            .ReleaseSafe => .@"128KiB",
            .ReleaseFast => .@"32KiB",
            .ReleaseSmall => .@"8KiB",
        };

        const unit = 1024;

        fn Usize(size: Stack) usize {
            debug.assert(@intFromEnum(size) < @intFromEnum(Stack.max_thread_stack));
            return @intFromEnum(size);
        }

        pub fn MiB(size: usize) Stack {
            debug.assert(size < unit);
            return @enumFromInt(size * unit * unit);
        }

        pub fn KiB(size: usize) Stack {
            debug.assert(size < unit);
            return @enumFromInt(size * unit);
        }
    };

    fn stackUsed(frame: *Frame) usize {
        if (builtin.mode != .Debug) @compileError("only available in Debug mode");
        // Stack grows downward — scan from bottom for the first non-0xAA byte
        // (Debug mode fills freed/unused memory with 0xAA)
        const stack = frame.stack_mem;
        var unused: usize = 0;
        while (unused < stack.len and stack[unused] == 0xAA) : (unused += 1) {}
        return (stack.len - unused) * @sizeOf(u8);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        comptime coroutine_fn: anytype,
        args: anytype,
        stack_size: ?Stack,
    ) *Frame {
        // Allocate Fiber/Frame Stack with abi alignment
        const stack: []align(raw_alignment) u8 = allocator.alignedAlloc(u8, Hardware.alignment, size: {
            const size = if (stack_size) |stack| stack.Usize() else Stack.auto.Usize();
            // stack_size should be aligned to `Hardware.alignment`
            debug.assert(Hardware.alignment.check(size));
            break :size switch (builtin.cpu.arch) {
                // In debug mode, the Dwarf unwinder for aarch64 requires a bit more
                // space for stack trace capturing for bookkeeping
                .aarch64, .aarch64_be => if (builtin.mode == .Debug) 2 * size else size,
                else => size,
            };
        }) catch @panic("OOM");

        const stack_base = @intFromPtr(stack.ptr);
        const stack_top = @intFromPtr(stack.ptr + stack.len);

        // space for the frame pointer
        const frame_ptr = Hardware.alignment.backward(
            stack_top - @sizeOf(Frame),
        );
        debug.assert(frame_ptr > stack_base);

        const frame: *Frame = @ptrFromInt(frame_ptr);

        const Args = @TypeOf(args);
        // space for the args pointer
        const args_ptr = Hardware.alignment.backward(
            frame_ptr - @sizeOf(Args),
        );
        debug.assert(args_ptr > stack_base);

        const arg_ptr: *Args = @ptrFromInt(args_ptr);
        arg_ptr.* = args;

        // setup space for the `Hardware.stack_count` of callee-saved registers
        const register_ptr = Hardware.alignment.backward(
            args_ptr - (@sizeOf(usize) * Hardware.stack_count),
        );
        debug.assert(register_ptr > stack_base);

        // address space for the callee-saved registers
        const register_entries: []FrameEntryFn = @as([*]FrameEntryFn, @ptrFromInt(
            register_ptr,
        ))[0..Hardware.stack_count];

        // A frame pointer of 0x0 denotes the root of the stack for the DWARF unwinder
        // so it knows where to stop unwinding.
        register_entries[Hardware.frame_ptr] = @ptrFromInt(0x0);

        // return address/instruction pointer we jump to for the execution of fiber's
        // entry point function after returning from `tardy_swap_frame`
        register_entries[Hardware.entry] = EntryFn(coroutine_fn, args);

        frame.* = .{
            .caller_sp = undefined,
            .current_sp = @ptrFromInt(register_ptr),
            .stack_mem = stack,
        };

        return frame;
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
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
    /// [0] %r15 pushq %r15 - Lowest Address (where %rsp points)
    /// [1] %r14 pushq %r14
    /// [2] %r13 pushq %r13
    /// [3] %r12 pushq %r12
    /// [4] %rbp pushq %rbp - Frame Pointer
    /// [5] %rbx pushq %rbx
    /// [6] RIP call (implicit) - Entry Function / Return Address
    pub const stack_count = 7;
    /// %rbp
    pub const frame_ptr = 4;
    /// Entry Function at Return Address (RIP)
    pub const entry = 6;
    pub const alignment: std.mem.Alignment = .@"16";

    extern fn tardy_swap_frame(
        noalias **align(raw_alignment) anyopaque,
        noalias **align(raw_alignment) anyopaque,
    ) callconv(.c) void;

    comptime {
        asm (@embedFile("asm/x86_64_sysv.asm"));
    }
};

const x64Windows = struct {
    /// [0] to [19] %xmm6 to %xmm15 - Takes up 20 indices (160 bytes total)
    /// [20] %r15 - First GPR popped (lowest address of pushed GPRs)
    /// [21] %r14
    /// [22] %r13
    /// [23] %r12
    /// [24] %rsi
    /// [25] %rdi
    /// [26] %rbp - Frame Pointer
    /// [27] %rbx
    /// [28] %gs:0x08 - Stack Base (Top of Stack)
    /// [29] %gs:0x10 - Stack Limit (Bottom of Stack)
    /// [30] RIP - Entry Function / Return Addres
    pub const stack_count = 31;
    /// %rbp
    pub const frame_ptr = 26;
    /// Return Address (RIP)
    pub const entry = 30;
    pub const alignment: std.mem.Alignment = .@"16";

    extern fn tardy_swap_frame(
        noalias **align(raw_alignment) anyopaque,
        noalias **align(raw_alignment) anyopaque,
    ) callconv(.c) void;

    comptime {
        asm (@embedFile("asm/x86_64_win.asm"));
    }
};

const aarch64General = struct {
    /// [0] fp (x29)  - Lowest Address / Frame Pointer
    /// [1] lr (x30) - Entry Function / Return Address
    /// [2] d8
    /// [3] d9
    /// [4] d10
    /// [5] d11
    /// [6] d12
    /// [7] d13
    /// [8] d14
    /// [9] d15
    /// [10] x19
    /// [11] x20
    /// [12] x21
    /// [13] x22
    /// [14] x23
    /// [15] x24
    /// [16] x25
    /// [17] x26
    /// [18] x27
    /// [19] x28 - Highest Address
    pub const stack_count = 20;
    /// Frame Pointer (FP)
    pub const frame_ptr = 0;
    /// Entry Function at Link Register (LR)
    pub const entry = 1;
    pub const alignment: std.mem.Alignment = .@"16";

    extern fn tardy_swap_frame(
        noalias **align(raw_alignment) anyopaque,
        noalias **align(raw_alignment) anyopaque,
    ) callconv(.c) void;

    comptime {
        // TODO: move assembly into `tardy_swap_frame` definition
        // TODO: allowzero for sp and check if 0x0 so I can skip part of the asm dance
        asm (@embedFile("asm/aarch64_gen.asm"));
    }
};
