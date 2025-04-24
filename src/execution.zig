const std = @import("std");
const VM = @import("VM.zig");
const Error = VM.Error;
const Code = VM.Code;

fn jump_table(opcode: VM.Op) *const fn (*VM) Error!void {
    return switch (opcode) {
        inline else => |inst| @field(instruction, @tagName(inst)),
    };
}

fn next(vm: *VM) Error!void {
    const opcode = vm.isr.current();
    vm.isr = vm.isr.step();
    return @call(.always_tail, jump_table(opcode), .{vm});
}

pub const start = instruction.nop;

const system = struct {
    pub fn read(vm: *VM) Error!void {
        const buf_addr, const fd: std.posix.fd_t = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        const buf = try vm.buffer_at(buf_addr);
        const bytes_read = std.posix.read(fd, buf) catch
            return error.syscall_failed;
        vm.data_stack.push(@bitCast(@as(u32, @truncate(bytes_read)))) catch
            unreachable;
    }

    pub fn write(vm: *VM) Error!void {
        const buf_addr, const fd: std.posix.fd_t = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        const buf = try vm.buffer_at(buf_addr);
        const bytes_written = std.posix.write(fd, buf) catch
            return error.syscall_failed;
        vm.data_stack.push(@bitCast(@as(u32, @truncate(bytes_written)))) catch
            unreachable;
    }
};

const instruction = struct {
    pub fn pc_fetch(vm: *VM) Error!void {
        vm.isr = Code.from_i32(try vm.load(.pc));
        vm.pc +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    pub fn jump(vm: *VM) Error!void {
        vm.pc = try vm.load(.pc);
        vm.isr = Code{};
        return @call(.always_tail, next, .{vm});
    }

    pub fn jump_zero(vm: *VM) Error!void {
        if (try vm.data_stack.top() == 0) {
            vm.pc = try vm.load(.pc);
            vm.isr = Code{};
        } else {
            vm.pc +%= 1;
        }
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn jump_plus(vm: *VM) Error!void {
        if (0 < try vm.data_stack.top()) {
            vm.pc = try vm.load(.pc);
            vm.isr = .{};
        } else {
            vm.pc +%= 1;
        }
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn call(vm: *VM) Error!void {
        try vm.return_stack.push(.{
            .pc = vm.pc +% 1,
            .isr = vm.isr,
        });
        vm.pc = try vm.load(.pc);
        vm.isr = .{};
        return @call(.always_tail, next, .{vm});
    }

    pub fn ret(vm: *VM) Error!void {
        const target = try vm.return_stack.top();
        vm.return_stack.pop() catch unreachable;
        vm.pc = target.pc;
        vm.isr = target.isr;
        return @call(.always_tail, next, .{vm});
    }

    pub fn halt(vm: *VM) Error!void {
        vm.done = true;
    }

    pub fn push_a(vm: *VM) Error!void {
        vm.a = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn pop_a(vm: *VM) Error!void {
        try vm.data_stack.push(vm.a);
        return @call(.always_tail, next, .{vm});
    }

    pub fn push_r(vm: *VM) Error!void {
        try vm.return_stack.push(.{ .pc = try vm.data_stack.top() });
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn pop_r(vm: *VM) Error!void {
        try vm.data_stack.push((try vm.return_stack.top()).pc);
        vm.return_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn over(vm: *VM) Error!void {
        const value, _ = try vm.data_stack.top2();
        try vm.data_stack.push(value);
        return @call(.always_tail, next, .{vm});
    }

    pub fn dup(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.data_stack.top());
        return @call(.always_tail, next, .{vm});
    }

    pub fn drop(vm: *VM) Error!void {
        try vm.data_stack.pop();
        return @call(.always_tail, next, .{vm});
    }

    pub fn swap(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[1]) catch unreachable;
        vm.data_stack.push(top[0]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn load_a(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.load(.a));
        return @call(.always_tail, next, .{vm});
    }

    pub fn store_a(vm: *VM) Error!void {
        try vm.store(.a);
        return @call(.always_tail, next, .{vm});
    }

    pub fn load_a_plus(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.load(.a));
        vm.a +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    pub fn store_a_plus(vm: *VM) Error!void {
        try vm.store(.a);
        vm.a +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    pub fn load_r_plus(vm: *VM) Error!void {
        const target = try vm.return_stack.top();
        try vm.data_stack.push(try vm.load(.r));
        vm.return_stack.pop() catch unreachable;
        vm.return_stack.push(.{
            .pc = target.pc +% 1,
            .isr = target.isr,
        }) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn store_r_plus(vm: *VM) Error!void {
        const target = try vm.return_stack.top();
        try vm.store(.r);
        vm.return_stack.pop() catch unreachable;
        vm.return_stack.push(.{
            .pc = target.pc +% 1,
            .isr = target.isr,
        }) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn literal(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.load(.pc));
        vm.pc +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    pub fn @"and"(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] & top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn not(vm: *VM) Error!void {
        const top = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        vm.data_stack.push(~top) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn @"or"(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] | top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn xor(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] ^ top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn plus(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] +% top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn double(vm: *VM) Error!void {
        const top = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        vm.data_stack.push(top << 1) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn half(vm: *VM) Error!void {
        const top = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        vm.data_stack.push(top >> 1) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    pub fn plus_star(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();

        if (top[1] & 1 == 1) {
            vm.data_stack.pop() catch unreachable;
            vm.data_stack.push(top[0] +% top[1]) catch unreachable;
        }
        return @call(.always_tail, next, .{vm});
    }

    pub fn nop(vm: *VM) Error!void {
        return @call(.always_tail, next, .{vm});
    }

    pub fn syscall(vm: *VM) Error!void {
        const top: u32 = @bitCast(try vm.data_stack.top());
        const syscall_id = std.meta.intToEnum(VM.Syscall, top) catch
            return error.unknown_syscall;
        vm.data_stack.pop() catch unreachable;
        try switch (syscall_id) {
            inline else => |id| @field(system, @tagName(id))(vm),
        };
        return @call(.always_tail, next, .{vm});
    }
};
