const std = @import("std");
const VM = @import("VM.zig");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const sample_word = .{
        .literal,
        .call,
        .halt,
    };

    const default_word = VM.Op.array_from_code(VM.Code.from_slice(&sample_word).?);

    try stdout.print("Run `zig build test` to run the tests.\n{any}\n{any}\n", .{ sample_word, default_word });

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var ram: [413]i32 = undefined;
    var vm = VM{.ram = &ram};

    _ = &vm;

}
