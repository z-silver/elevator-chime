const std = @import("std");
const VM = @import("VM.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) return error.no_file_given;

    const image_file = try std.fs.cwd().openFile(args[1], .{});
    defer image_file.close();

    const image = try image_file.readToEndAllocOptions(
        allocator,
        VM.max_ram_size,
        null,
        @alignOf(i32),
        null,
    );
    var vm = VM{ .ram = std.mem.bytesAsSlice(i32, image) };
    for (vm.ram, 0..) |word, index| {
        if (index == 8) break;
        std.debug.print("word: {x}\n", .{word});
    }
    try vm.run();
}
