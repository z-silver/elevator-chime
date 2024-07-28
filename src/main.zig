const std = @import("std");
const VM = @import("VM.zig");

pub fn main() !void {
    const buffer_init: [32]u8 = "000000000000000000000000000000\x00\x00".*;
    var echo_image = [_]i32{
        VM.Code.from_slice(&.{
            .literal,
            .literal,
            .literal,
            .syscall,
        }).?.to_i32(),
        8,
        0, // stdin
        @intFromEnum(VM.Syscall.read),
        VM.Code.from_slice(&.{
            .literal,
            .literal,
            .literal,
            .syscall,
            .halt,
        }).?.to_i32(),
        8,
        1, // stdout
        @intFromEnum(VM.Syscall.write),
        // 8
        30,
    } ++ @as([8]i32, @bitCast(buffer_init));

    VM.image_native_to_big(&echo_image);
    var vm_storage = VM{ .ram = &echo_image };
    const vm = &vm_storage;

    try vm.run();
}
