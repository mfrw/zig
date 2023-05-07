const std = @import("std");
const Order = std.math.Order;

const RangeSet = @This();
const Module = @import("Module.zig");
const SwitchProngSrc = @import("Module.zig").SwitchProngSrc;
const Type = @import("type.zig").Type;
const Value = @import("value.zig").Value;

ranges: std.ArrayList(Range),
module: *Module,

pub const Range = struct {
    first: Value,
    last: Value,
    src: SwitchProngSrc,
};

pub fn init(allocator: std.mem.Allocator, module: *Module) RangeSet {
    return .{
        .ranges = std.ArrayList(Range).init(allocator),
        .module = module,
    };
}

pub fn deinit(self: *RangeSet) void {
    self.ranges.deinit();
}

pub fn add(
    self: *RangeSet,
    first: Value,
    last: Value,
    ty: Type,
    src: SwitchProngSrc,
) !?SwitchProngSrc {
    for (self.ranges.items) |range| {
        if (last.compareScalar(.gte, range.first, ty, self.module) and
            first.compareScalar(.lte, range.last, ty, self.module))
        {
            return range.src; // They overlap.
        }
    }
    try self.ranges.append(.{
        .first = first,
        .last = last,
        .src = src,
    });
    return null;
}

const LessThanContext = struct { ty: Type, module: *Module };

/// Assumes a and b do not overlap
fn lessThan(ctx: LessThanContext, a: Range, b: Range) bool {
    return a.first.compareScalar(.lt, b.first, ctx.ty, ctx.module);
}

pub fn spans(self: *RangeSet, first: Value, last: Value, ty: Type) !bool {
    if (self.ranges.items.len == 0)
        return false;

    const mod = self.module;
    std.mem.sort(Range, self.ranges.items, LessThanContext{
        .ty = ty,
        .module = mod,
    }, lessThan);

    if (!self.ranges.items[0].first.eql(first, ty, mod) or
        !self.ranges.items[self.ranges.items.len - 1].last.eql(last, ty, mod))
    {
        return false;
    }

    var space: Value.BigIntSpace = undefined;

    var counter = try std.math.big.int.Managed.init(self.ranges.allocator);
    defer counter.deinit();

    // look for gaps
    for (self.ranges.items[1..], 0..) |cur, i| {
        // i starts counting from the second item.
        const prev = self.ranges.items[i];

        // prev.last + 1 == cur.first
        try counter.copy(prev.last.toBigInt(&space, mod));
        try counter.addScalar(&counter, 1);

        const cur_start_int = cur.first.toBigInt(&space, mod);
        if (!cur_start_int.eq(counter.toConst())) {
            return false;
        }
    }

    return true;
}
