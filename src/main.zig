const std = @import("std");
const VM = @import("VM.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.no_file_given;

    const image_file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer image_file.close(io);

    var image_reader = image_file.reader(io, &.{});

    const image = try image_reader.interface.allocRemainingAlignedSentinel(
        arena,
        .limited(VM.max_ram_size),
        .of(i32),
        null,
    );
    var vm: VM = .init(io, std.mem.bytesAsSlice(i32, image));
    try vm.run();
}

test {
    _ = VM;
}
