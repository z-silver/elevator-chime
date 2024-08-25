const std = @import("std");
const data = @import("data.zig");
const assert = std.debug.assert;

pub const Dialect = std.StaticStringMap(data.Op);
pub const Environment = std.StringHashMap(i32);
const Memory = std.ArrayList(i32);

pub fn parse(
    allocator: std.mem.Allocator,
    dialect: Dialect,
    source: []const u8,
    error_position: *u32,
) ![]i32 {
    var parser = try Parser.init(
        allocator,
        dialect,
        source,
        error_position,
    );
    defer parser.deinit();
    return parser.run();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    dialect: Dialect,
    source: []const u8,
    error_position: *u32,
    labels: Environment,
    constants: Environment,
    memory: Memory,

    pub fn init(
        allocator: std.mem.Allocator,
        dialect: Dialect,
        source: []const u8,
        error_position: *u32,
    ) !Parser {
        assert(source.len < std.math.maxInt(u32) + 2);
        var memory = Memory.init(allocator);
        errdefer memory.deinit();

        var labels = Environment.init(allocator);
        errdefer labels.deinit();

        var constants = Environment.init(allocator);
        errdefer constants.deinit();

        return .{
            .allocator = allocator,
            .dialect = dialect,
            .memory = memory,
            .labels = labels,
            .constants = constants,
            .error_position = error_position,
            .source = source,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.memory.deinit();
        free_keys_and_deinit(self.allocator, &self.labels);
        free_keys_and_deinit(self.allocator, &self.constants);
    }

    pub fn run(self: *Parser) ![]i32 {
        try self.collect_names();
        try self.assemble();
        return self.memory.toOwnedSlice();
    }

    fn collect_names(self: *Parser) !void {
        var memory_address: i32 = 0;
        var lines = std.mem.tokenizeScalar(u8, self.source, '\n');
        var current_line: u32 = 0;
        errdefer self.error_position.* = current_line;
        while (lines.next()) |line| {
            current_line +|= 1;
            var words = std.mem.tokenizeAny(u8, line, " \t\r");
            if (words.peek()) |word| {
                switch (word[0]) {
                    ':' => {
                        const entry = try self.labels.getOrPut(word[1..]);
                        if (entry.found_existing) return error.label_collision;
                        entry.value_ptr.* = memory_address;
                    },
                    '>' => {
                        const entry = try self.constants.getOrPut(word[1..]);
                        if (entry.found_existing) return error.constant_collision;
                        entry.value_ptr.* = try parse_line(line);
                    },
                    else => {},
                }
                memory_address +%= @bitCast(try line_size(line));
            }
        }
    }

    fn assemble(self: *Parser) !void {
        _ = self; // autofix
        unreachable;
    }

    fn free_keys_and_deinit(
        allocator: std.mem.Allocator,
        map: *Environment,
    ) void {
        var keys = map.keyIterator();
        while (keys.next()) |key| {
            allocator.free(key.*);
        }
        map.deinit();
    }
};


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

fn any_whitespace(subject: []const u8) []const u8 {
    return for (subject, 0..) |character, index| {
        if (!whitespace.has(&.{character}))
            break subject[index..];
    } else subject;
}

const With_Capture = struct {
    capture: []const u8,
    remainder: []const u8,
};

fn one_word(subject: []const u8) ?With_Capture {
    const no_leading_whitespace = any_whitespace(subject);
    return if (no_leading_whitespace.len == 0)
        null
    else for (no_leading_whitespace, 0..) |character, index| {
        if (whitespace.has(&.{character})) {
            assert(index != 0);
            break .{
                .capture = no_leading_whitespace[0 .. index - 1],
                .remainder = no_leading_whitespace[index..],
            };
        }
    } else .{
        .capture = no_leading_whitespace,
        .remainder = "",
    };
}

fn string_line_size_impl(comptime nested: bool, line: []const u8) !u32 {
    if (one_word(line)) |word| {
        return switch (word.capture[0]) {
            ':' => if (nested)
                error.invalid_line
            else
                string_line_size_impl(true, word.remainder),
            '"' => unreachable, // FIXME
            else => error.not_actually_a_string,
        };
    } else return error.empty_line;
}

fn string_line_size(line: []const u8) !u32 {
    return string_line_size_impl(false, line);
}

fn line_size(line: []const u8) !u32 {
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    if (words.peek() == null) return 0;
    return while (words.next()) |word| {
        break switch (word[0]) {
            '>' => 0,
            ':' => continue,
            '"' => try string_line_size(line),
            else => 1,
        };
    } else 1;
}

fn parse_line(_: []const u8) !i32 {
    unreachable; // FIXME
}

test "everything" {
    std.testing.refAllDecls(@This());
}
