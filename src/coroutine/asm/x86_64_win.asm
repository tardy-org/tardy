.global tardy_swap_frame

tardy_swap_frame:
    // Windows stores the upper and lower bounds of the current thread's stack in the
    // Thread Information Block (TIB), which is accessed via the %gs segment register.
    // If a Windows exception occurs (or the stack needs to grow), the OS checks if the
    // current %rsp is within these two limits. If you swap to a new fiber's stack
    // without updating the TIB, Windows will instantly kill your program with an Access
    // Violation. By pushing and popping these %gs values, you are ensuring the OS's
    // internal stack boundary records are swapped alongside the CPU registers.

    // Stack Limit (the lowest memory address / end of the stack)
    pushq %gs:0x10
    // Stack Base (the highest memory address / start of the stack)
    pushq %gs:0x08

    // Windows additionaly has rdi and rsi as callee saved registers
    pushq %rbx
    pushq %rbp
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    // allocate 160 bytes of space for the 10, 16 bytes (128 bits) %xmmN registers
    subq $160, %rsp
    movups %xmm6, 0x00(%rsp)
    movups %xmm7, 0x10(%rsp)
    movups %xmm8, 0x20(%rsp)
    movups %xmm9, 0x30(%rsp)
    movups %xmm10, 0x40(%rsp)
    movups %xmm11, 0x50(%rsp)
    movups %xmm12, 0x60(%rsp)
    movups %xmm13, 0x70(%rsp)
    movups %xmm14, 0x80(%rsp)
    movups %xmm15, 0x90(%rsp)

    // stack swap
    // Saves the current CPU Stack Pointer %rsp into the 1st arg (%rcx)
    // of `tardy_swap_frame` **old_sp
    movq %rsp, (%rcx)
    // load the %rdx address (from the 2nd arg of `tardy_swap_frame` **new_sp) and
    // overwrites the CPU's Stack Pointer. The CPU is now executing on the new fiber's
    // stack.
    movq (%rdx), %rsp

    // Setup new Fibre stack for execution (it follow SysV in spirit)
    movups 0x00(%rsp), %xmm6
    movups 0x10(%rsp), %xmm7
    movups 0x20(%rsp), %xmm8
    movups 0x30(%rsp), %xmm9
    movups 0x40(%rsp), %xmm10
    movups 0x50(%rsp), %xmm11
    movups 0x60(%rsp), %xmm12
    movups 0x70(%rsp), %xmm13
    movups 0x80(%rsp), %xmm14
    movups 0x90(%rsp), %xmm15
    addq $160, %rsp

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbp
    popq %rbx

    popq %gs:0x08
    popq %gs:0x10

    retq
