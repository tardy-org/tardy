const SwapFn = *const fn (
    noalias paused_sp: **align(raw_alignment) anyopaque,
    noalias next_executing_sp: **align(raw_alignment) anyopaque,
) callconv(.c) void;

pub const raw_alignment = Frame.alignment.toByteUnits();

pub const Frame = switch (builtin.cpu.arch) {
    .x86_64 => switch (builtin.os.tag) {
        .windows => x64Windows,
        else => x64SysV,
    },
    .aarch64 => aarch64General,
    else => @compileError("Architecture not currently supported!"),
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
    pub const alignment: mem.Alignment = .@"16";

    fn swap_frame(
        noalias paused_sp: **align(raw_alignment) anyopaque,
        noalias next_executing_sp: **align(raw_alignment) anyopaque,
    ) void {
        const Fn = struct {
            fn swap() callconv(.naked) void {
                asm volatile (
                    \\ # save non-volatile callee saved registers
                    \\ # the return Address (RIP) is implicitly pushed onto the stack
                    \\ # by the `call` instruction that invoked this function making
                    \\ # the number of registers 7
                    \\ pushq %%rbx
                    \\ pushq %%rbp
                    \\ pushq %%r12
                    \\ pushq %%r13
                    \\ pushq %%r14
                    \\ pushq %%r15
                    \\
                    \\ # swap stacks
                    \\ # *paused_sp = current %rsp
                    \\ movq %%rsp, (%%rdi)
                    \\ # %rsp = *next_executing_sp %rsi — now executing the new frame
                    \\ movq (%%rsi), %%rsp
                    \\
                    \\ # restore callee-saved registers for the frame we just entered
                    \\ popq %%r15
                    \\ popq %%r14
                    \\ popq %%r13
                    \\ popq %%r12
                    \\ popq %%rbp
                    \\ popq %%rbx
                    \\
                    \\ # Pop the return address off (new) the stack into a volatile
                    \\ # caller saved scratch register
                    \\ popq %%r9
                );
                if (cfiEnabled()) asm volatile (
                    \\ # Tell the unwinder there is no valid caller frame beyond this
                    \\ # point. RIP is undefined here, cleanly terminating the chain at
                    \\ # this switch boundary.
                    \\ .cfi_undefined %%rip
                );
                asm volatile (
                    \\ # jump to execute the EntryFn function at the %r9 address
                    \\ jmpq *%%r9
                );
            }
        };

        const swap_fn: SwapFn = @ptrCast(&Fn.swap);
        swap_fn(paused_sp, next_executing_sp);
    }
};

// TODO: reduce and report `unknow size: 0xx(%%rsp)` issue with non llvm backend
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
    pub const alignment: mem.Alignment = .@"16";

    fn swap_frame(
        noalias paused_sp: **align(raw_alignment) anyopaque,
        noalias next_executing_sp: **align(raw_alignment) anyopaque,
    ) void {
        const Fn = struct {
            fn swap() callconv(.naked) void {
                if (cfiEnabled()) asm volatile (".cfi_startproc");
                asm volatile (
                    \\ # Windows stores the upper and lower bounds of the current
                    \\ # thread's stack in the Thread Information Block (TIB), which
                    \\ # is accessed via the %gs segment register.
                    \\ # If a Windows checks to ensure your current %rsp is within
                    \\ # these limits. We save these %gs values, ensuring the OS's
                    \\ # internal stack boundary records are swapped alongside the CPU
                    \\ # registers.
                    \\
                    \\ # Stack Top/Limit
                    \\ pushq %%gs:0x10
                    \\ # Stack Base
                    \\ pushq %%gs:0x08
                    \\
                    \\ # Windows additionaly has rdi and rsi as callee saved registers
                    \\ pushq %%rbx
                    \\ pushq %%rbp
                    \\ pushq %%rdi
                    \\ pushq %%rsi
                    \\ pushq %%r12
                    \\ pushq %%r13
                    \\ pushq %%r14
                    \\ pushq %%r15
                    \\
                    \\ # allocate 160 bytes of space for the 10 x 16 bytes (128 bits)
                    \\ # %xmmN registers
                    \\ subq $160, %%rsp
                    \\
                    \\ movups %%xmm6, 0x00(%rsp)
                    \\ movups %%xmm7, 0x10(%%rsp)
                    \\ movups %%xmm8, 0x20(%%rsp)
                    \\ movups %%xmm9, 0x30(%%rsp)
                    \\ movups %%xmm10, 0x40(%%rsp)
                    \\ movups %%xmm11, 0x50(%%rsp)
                    \\ movups %%xmm12, 0x60(%%rsp)
                    \\ movups %%xmm13, 0x70(%%rsp)
                    \\ movups %%xmm14, 0x80(%%rsp)
                    \\ movups %%xmm15, 0x90(%%rsp)
                    \\
                    \\ # swap stacks
                    \\ # *paused_sp (%rcx) = current %rsp
                    \\ movq %%rsp, (%%rcx)
                    \\ # %rsp = *next_executing_sp %rdx — now executing the new frame
                    \\ movq (%%rdx), %%rsp
                    \\
                    \\ # Setup new Fibre stack for execution (it follow SysV in spirit)
                    \\ movups 0x00(%%rsp), %%xmm6
                    \\ movups 0x10(%%rsp), %%xmm7
                    \\ movups 0x20(%%rsp), %%xmm8
                    \\ movups 0x30(%%rsp), %%xmm9
                    \\ movups 0x40(%%rsp), %%xmm10
                    \\ movups 0x50(%%rsp), %%xmm11
                    \\ movups 0x60(%%rsp), %%xmm12
                    \\ movups 0x70(%%rsp), %%xmm13
                    \\ movups 0x80(%%rsp), %%xmm14
                    \\ movups 0x90(%%rsp), %%xmm15
                    \\
                    \\ addq $160, %%rsp
                    \\
                    \\ popq %%r15
                    \\ popq %%r14
                    \\ popq %%r13
                    \\ popq %%r12
                    \\ popq %%rsi
                    \\ popq %%rdi
                    \\ popq %%rbp
                    \\ popq %%rbx
                    \\
                    \\ popq %%gs:0x08
                    \\ popq %%gs:0x10
                    \\
                    \\ # Pop the return address off (new) the stack into a volatile
                    \\ # caller saved scratch register
                    \\ popq %%r9
                );
                if (cfiEnabled()) asm volatile (
                    \\ # Tell the unwinder there is no valid caller frame beyond this
                    \\ # point. RIP is undefined here, cleanly terminating the chain at
                    \\ # this switch boundary.
                    \\ .cfi_undefined %%rip
                );
                asm volatile (
                    \\ # jump to execute the EntryFn function at the %r9 address
                    \\ jmpq *%%r9
                );
                if (cfiEnabled()) asm volatile (".cfi_endproc");
            }
        };

        const swap_fn: SwapFn = @ptrCast(&Fn.swap);
        swap_fn(paused_sp, next_executing_sp);
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
    pub const alignment: mem.Alignment = .@"16";

    fn swap_frame(
        noalias paused_sp: **align(raw_alignment) anyopaque,
        noalias next_executing_sp: **align(raw_alignment) anyopaque,
    ) void {
        // https://www.wasilzafar.com/pages/series/arm-assembly/arm-assembly-06-stack-subroutines.html
        const Fn = struct {
            fn swap() callconv(.naked) void {
                // TODO: allowzero for sp and check if 0x0 so I can skip part
                // of the asm dance
                asm volatile (
                    \\ # store non-volatile state of current Fibre to its stack
                    \\ stp fp, lr, [sp, #-20*8]!
                    \\ stp d8, d9, [sp, #2*8]
                    \\ stp d10, d11, [sp, #4*8]
                    \\ stp d12, d13, [sp, #6*8]
                    \\ stp d14, d15, [sp, #8*8]
                    \\ stp x19, x20, [sp, #10*8]
                    \\ stp x21, x22, [sp, #12*8]
                    \\ stp x23, x24, [sp, #14*8]
                    \\ stp x25, x26, [sp, #16*8]
                    \\ stp x27, x28, [sp, #18*8]
                    \\
                    \\ # Copy the current Stack Pointer into a temporary/volatile
                    \\ # register (x9)
                    \\ mov x9, sp
                    \\ # Save the old frame's Stack Pointer into the pointer address
                    \\ # held in x0 (*paused_sp)
                    \\ str x9, [x0]
                    \\ # Load the new fiber's Stack Pointer from the address held in
                    \\ # x1 (*next_executing_sp) into x9
                    \\ ldr x9, [x1]
                    \\ # Overwrite the CPU's Stack Pointer.
                    \\ # The CPU is now executing on the new fiber's stack!
                    \\ mov sp, x9
                    \\
                    \\ # load the state of the new frame into the CPU registers.
                    \\ ldp x27, x28, [sp, #18*8]
                    \\ ldp x25, x26, [sp, #16*8]
                    \\ ldp x23, x24, [sp, #14*8]
                    \\ ldp x21, x22, [sp, #12*8]
                    \\ ldp x19, x20, [sp, #10*8]
                    \\ ldp d14, d15, [sp, #8*8]
                    \\ ldp d12, d13, [sp, #6*8]
                    \\ ldp d10, d11, [sp, #4*8]
                    \\ ldp d8, d9, [sp, #2*8]
                    \\ ldp fp, lr, [sp], #20*8
                    \\
                    \\ # Pop the return address into `x9` a caller saved temporary
                    \\ # register
                    \\ mov x9, lr
                );
                if (cfiEnabled()) asm volatile (
                    \\ # Tell the unwinder there is no valid caller frame above this
                    \\ # point — stop walking here rather than following a stale/zeroed
                    \\ # lr into unrelated memory.
                    \\ .cfi_undefined lr
                );
                asm volatile (
                    \\ # Zero out LR so that when the `func` inside EntryFn code starts
                    \\ # it will save LR=0 to the stack cleanly terminating the DWARF
                    \\ # unwinder and preventing it from trying to capture stack traces
                    \\ # outside of the Fibre's stack space.
                    \\ mov lr, xzr
                    \\
                    \\ ret x9
                );
            }
        };

        const swap_fn: SwapFn = @ptrCast(&Fn.swap);
        swap_fn(paused_sp, next_executing_sp);
    }
};

/// This is the start of the newly entered frame. Prevent DWARF-based unwinders from
/// unwinding further. We prevent FP-based unwinders from unwinding further by
/// zeroing the return/link registers in the various asm.
inline fn cfiEnabled() bool {
    return builtin.unwind_tables != .none or !builtin.strip_debug_info;
}

const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
