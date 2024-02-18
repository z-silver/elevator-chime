const std = @import("std");
const Int = std.meta.Int;

pub const Code_Int = Int(.unsigned, 32 - Op.leftover_bits);

pub const Code = packed struct(Code_Int) {
    int: Code_Int = 0,

    pub fn from_i32(word: i32) Code {
        return .{ .int = @truncate(@as(u32, @bitCast(word)) >> Op.leftover_bits) };
    }

    pub fn to_i32(code: Code) i32 {
        return @bitCast(@as(u32, code.int) << Op.leftover_bits);
    }

    test "code to i32 roundtrip" {
        const initial = comptime try Code.from_slice(&.{
            .literal,
            .call,
            .dup,
            .over,
            .plus,
            .halt,
        });

        const final = comptime Code.from_i32(initial.to_i32());

        try std.testing.expectEqual(initial, final);
    }

    pub fn current(code: Code) Op {
        return @enumFromInt(@as(u5, @truncate(
            code.int >> (@bitSizeOf(Op) * (Op.per_word - 1)),
        )));
    }

    test "the current op is the top bits in a code word" {
        const code = comptime try from_slice(&.{.load_a_plus});
        try std.testing.expectEqual(0b10000, @intFromEnum(comptime code.current()));
    }

    pub fn step(code: Code) Code {
        return .{ .int = code.int << Op.width };
    }

    test "stepping through a code word introduces a PC fetch" {
        const initial = comptime try Code.from_slice(&(.{.literal} ** 6));
        const final = comptime Op.array_from_code(initial.step());

        try std.testing.expectEqual(Op.pc_fetch, final[final.len - 1]);
    }

    pub fn add(code: Code, op: Op) Code {
        return .{ .int = code.int << Op.width | @intFromEnum(op) };
    }

    pub fn from_slice(ops: []const Op) !Code {
        return if (Op.per_word < ops.len)
            error.InvalidArgument
        else result: {
            var word = Code{};
            for (0..Op.per_word) |index| {
                word = word.add(
                    if (index < ops.len)
                        ops[index]
                    else
                        Op.pc_fetch,
                );
            }
            break :result word;
        };
    }
};

const op_backing_type = u5;

pub const Op = enum(op_backing_type) {
    pub const backing_type = op_backing_type;
    pub const width = @bitSizeOf(backing_type);
    pub const per_word = 32 / width;
    pub const leftover_bits = 32 % width;

    pub fn array_from_code(word: Code) [per_word]Op {
        const uword: u32 = @bitCast(word.to_i32());
        var ops: [per_word]Op = undefined;
        for (0..per_word) |index| {
            const reverse_index = per_word - index - 1;
            const offset: u5 = @truncate(reverse_index * width + leftover_bits);
            const op_number: u5 = @truncate(uword >> offset);
            ops[index] = @enumFromInt(op_number);
        }
        return ops;
    }

    test "op array roundtrip" {
        const initial = [_]Op{
            .literal,
            .literal,
            .plus,
            .halt,
            .pc_fetch,
            .pc_fetch,
        };

        const code = comptime try Code.from_slice(&initial);
        const final = comptime array_from_code(code);
        try std.testing.expectEqual(initial, final);
    }

    test "defaults" {
        const default_word = comptime Op.array_from_code(.{});
        try std.testing.expectEqual([_]Op{.pc_fetch} ** 6, default_word);
    }

    test "PC fetch instruction is represented as 0" {
        try std.testing.expectEqual(0, @intFromEnum(Op.pc_fetch));
    }

    // Control Flow
    pc_fetch = 0,
    jump = 1,
    jump_zero = 2,
    jump_plus = 3,
    call = 4,
    ret = 5,
    halt = 6,

    // Stack Manipulation
    push_a = 7,
    pop_a = 8,
    push_r = 9,
    pop_r = 10,
    over = 11,
    dup = 12,
    drop = 13,

    // Memory
    load_a = 14,
    store_a = 15,
    load_a_plus = 16,
    store_a_plus = 17,
    load_r_plus = 18,
    store_r_plus = 19,
    literal = 20,

    // Arithmetic
    @"and" = 21,
    not = 22,
    @"or" = 23,
    xor = 24,
    plus = 25,
    double = 26,
    half = 27,
    plus_star = 28,

    // Other
    nop = 29,
    syscall = 30,
};
