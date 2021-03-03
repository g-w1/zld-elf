export fn exit(code: c_int) callconv(.C) noreturn {
    asm volatile ("syscall"
        :
        : [number] "{rax}" (@as(c_int, 231)),
          [arg1] "{rdi}" (code)
        : "rcx", "r11", "memory"
    );
    unreachable;
}
