// https://www.wasilzafar.com/pages/series/arm-assembly/arm-assembly-06-stack-subroutines.html
.global _tardy_swap_frame
.global tardy_swap_frame

_tardy_swap_frame:
tardy_swap_frame:
      // store non-volatile state of current Fibre to its stack
      stp fp, lr, [sp, #-20*8]!
      stp d8, d9, [sp, #2*8]
      stp d10, d11, [sp, #4*8]
      stp d12, d13, [sp, #6*8]
      stp d14, d15, [sp, #8*8]
      stp x19, x20, [sp, #10*8]
      stp x21, x22, [sp, #12*8]
      stp x23, x24, [sp, #14*8]
      stp x25, x26, [sp, #16*8]
      stp x27, x28, [sp, #18*8]

      // Copy the current Stack Pointer into a temporary/volatile register (x9)
      mov x9, sp
      // Save the old fiber's Stack Pointer into the pointer address held in x0 (*sp)
      str x9, [x0]
      // Load the new fiber's Stack Pointer from the address held in x1 (*sp) into x9
      ldr x9, [x1]
      // Overwrite the CPU's Stack Pointer.
      // The CPU is now executing on the new fiber's stack!
      mov sp, x9

      // load the state of the new fiber into the CPU registers.
      ldp x27, x28, [sp, #18*8]
      ldp x25, x26, [sp, #16*8]
      ldp x23, x24, [sp, #14*8]
      ldp x21, x22, [sp, #12*8]
      ldp x19, x20, [sp, #10*8]
      ldp d14, d15, [sp, #8*8]
      ldp d12, d13, [sp, #6*8]
      ldp d10, d11, [sp, #4*8]
      ldp d8, d9, [sp, #2*8]
      ldp fp, lr, [sp], #20*8

      // Pop the return address into x9 (a caller saved temporary register)
      mov x9, lr

      // Zero out LR so that when the `func` inside EntryFn code starts, it will save
      // LR=0 to the stack cleanly terminating the DWARF unwinder and preventing it from
      // trying to capture stack traces outside of the Fibre's stack space.
      mov lr, xzr

      ret x9
