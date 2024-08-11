const std = @import("std");
const data = @import("data.zig");
const assert = std.debug.assert;

const Chaff = @This();

allocator: std.mem.Allocator,
dialect: Dialect = lemos_dialect,

pub const Dialect = std.StaticStringMap(data.Op);
pub const Environment = std.StringHashMap(i32);

pub const lemos_dialect = Dialect.initComptime(.{
    .{ "fetch", .pc_fetch },
    .{ "jump", .jump },
    .{ "jump-0", .jump_zero },
    .{ "jump+", .jump_plus },
    .{ "call", .call },
    .{ "ret", .ret },
    .{ "halt", .halt },
    .{ "push-a", .push_a },
    .{ "pop-a", .pop_a },
    .{ "push-r", .push_r },
    .{ "pop-r", .pop_r },
    .{ "over", .over },
    .{ "dup", .dup },
    .{ "drop", .drop },
    .{ "load-a", .load_a },
    .{ "store-a", .store_a },
    .{ "load-a-plus", .load_a_plus },
    .{ "store-a-plus", .store_a_plus },
    .{ "load-r-plus", .load_r_plus },
    .{ "store-r-plus", .store_r_plus },
    .{ "literal", .literal },
    .{ "and", .@"and" },
    .{ "not", .not },
    .{ "or", .@"or" },
    .{ "xor", .xor },
    .{ "plus", .plus },
    .{ "double", .double },
    .{ "/2", .half },
    .{ "+*", .plus_star },
    .{ "nop", .nop },
    .{ "syscall", .syscall },
    .{ "swap", .swap },
});

comptime {
    const total_opcodes = @typeInfo(data.Op).Enum.fields.len;
    const Instruction_Set = std.StaticBitSet(total_opcodes);
    var instruction_set = Instruction_Set.initEmpty();
    for (lemos_dialect.values()) |op| {
        instruction_set.set(@intFromEnum(op));
    }
    assert(instruction_set.eql(Instruction_Set.initFull()));
}

const whitespace = std.StaticStringMap(void).initComptime(
    .{ .{" "}, .{"\t"}, .{"\n"}, .{"\r"} },
);

fn free_keys_and_deinit(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(u32),
) void {
    var keys = map.keyIterator();
    while (keys.next()) |key| {
        allocator.free(key.*);
    }
    map.deinit();
}

fn string_line_size(_: []const u8) u32 {
    //FIXME
    return 1;
}

fn line_size(line: []const u8) u32 {
    var words = std.mem.tokenizeAny(line, " \t\r");
    if (words.peek() == null) return 0;
    return while (words.next()) |word| {
        break switch (word[0]) {
            '>' => 0,
            ':' => continue,
            '"' => string_line_size(line),
            else => 1,
        };
    } else 1;
}

fn collect_names(
    labels: *Environment,
    constants: *Environment,
    source: []const u8,
) !void {
    var memory_address: i32 = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        if (words.peek()) |word| {
            if (switch (word[0]) {
                ':' => labels,
                '>' => constants,
                else => null,
            }) |target| {
                const entry = try target.getOrPut(word[1..]);
                if (entry.found_existing) return error.name_collision;

                entry.value_ptr.* = memory_address;
            }
            memory_address +%= try line_size(line);
        }
    }
}

pub fn parse(
    self: Chaff,
    source: []const u8,
) ![]i32 {
    // TODO: report the line number in which an error occurred
    assert(source.len < std.math.maxInt(u32) + 2);
    const allocator = self.allocator;

    var memory = std.ArrayList(i32).init(allocator);
    errdefer memory.deinit();

    var labels = Environment.init(allocator);
    defer free_keys_and_deinit(allocator, &labels);

    var constants = Environment.init(allocator);
    defer free_keys_and_deinit(allocator, &constants);

    try collect_names(&labels, &constants, source);

    return memory.toOwnedSlice();
}
