extern fn exit(code: c_int) callconv(.C) noreturn;

export fn _start() void {
    exit(20);
}
