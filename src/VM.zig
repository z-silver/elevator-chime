const std = @import("std");
const Int = std.meta.Int;
const data = @import("data.zig");
pub const Op = data.Op;
pub const Code = data.Code;

ram: []i32,

data_stack: Stack(64, i32) = .{},
return_stack: Stack(64, Return_Frame) = .{},
pc: i32 = 0,
isr: Code = .{},
a: i32 = 0,

pub const Return_Frame = struct {
    pc: i32 = 0,
    isr: Code = .{},
};

pub fn Stack(comptime n: usize, comptime T: type) type {
    if (n < 8) @compileError("Stack capacity too small");
    return struct {
        const Stack_Size = Int(.unsigned, @bitSizeOf(@TypeOf(n)) - @clz(n));
        size: Stack_Size = 0,
        array: [n]T = undefined,

        pub const capacity: Stack_Size = n;

        pub fn top(self: *const @This()) !T {
            return if (self.size == 0)
                error.InvalidStackOperation
            else
                self.array[self.size - 1];
        }

        pub fn push(self: *@This(), item: T) !void {
            if (self.size == capacity) {
                return error.InvalidStackOperation;
            }
            self.array[self.size] = item;
            self.size += 1;
            return;
        }

        pub fn pop(self: *@This()) !void {
            if (self.size == 0) return error.InvalidStackOperation;
            self.size -= 1;
            return;
        }
    };
}

pub fn step(vm: *@This()) !void {
    const current_instruction = vm.isr.current();
    vm.isr = vm.isr.step();

    switch (current_instruction) {}
}
