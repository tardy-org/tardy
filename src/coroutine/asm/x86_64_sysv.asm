.global _tardy_swap_frame
.global tardy_swap_frame

_tardy_swap_frame:
tardy_swap_frame:
    // save non-volatile callee saved registers
    // Return Address (RIP) is implicitly pushed onto the stack by the call instruction
    // that invoked this function making 7 registers
    // pushq automatically subtracts 8 from the Stack Pointer (%rsp) and writes the
    // 64-bit register to that memory address
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    // swap stacks
    // Saves the current CPU Stack Pointer %rsp into the 1st arg (%rdi)
    // of `tardy_swap_frame` **old_sp
    movq %rsp, (%rdi)
    // load the %rsi address (from the 2nd arg of `tardy_swap_frame` **new_sp) and
    // overwrites the CPU's Stack Pointer. The CPU is now executing on the new fiber's
    // stack.
    movq (%rsi), %rsp

    // popq read the 8 bytes at %rsp into the register and then automatically
    // add 8 to %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx

    // retq pops the final 8 bytes off the stack (which is the Return Address) directly
    // into the CPU's Instruction Pointer (RIP) and jumps to it to execute the function
    // in EntryFn
    retq
