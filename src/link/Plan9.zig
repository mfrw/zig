const Plan9 = @This();

const std = @import("std");
const link = @import("../link.zig");
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const aout = @import("plan9/a.out.zig");
const codegen = @import("../codegen.zig");
const trace = @import("../tracy.zig").trace;
const mem = std.mem;
const File = link.File;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.link);
const assert = std.debug.assert;

// TODO use incremental compilation

base: link.File,
ptr_width: PtrWidth,
error_flags: File.ErrorFlags = File.ErrorFlags{},

decl_table: std.AutoArrayHashMapUnmanaged(*Module.Decl, void) = .{},
/// is just casted down when 32 bit
syms: std.ArrayListUnmanaged(aout.Sym64) = .{},
call_relocs: std.ArrayListUnmanaged(CallReloc) = .{},
text_buf: std.ArrayListUnmanaged(u8) = .{},
data_buf: std.ArrayListUnmanaged(u8) = .{},

cur_decl: *Module.Decl = undefined,
hdr: aout.ExecHdr = undefined,

fn headerSize(self: Plan9) u32 {
    // fat header (currently unused)
    const fat: u4 = if (self.ptr_width == .p64) 8 else 0;
    return aout.ExecHdr.size() + fat;
}
pub const DeclBlock = struct {
    type: enum { text, data },
    // offset in the text or data sects
    offset: u32,
    pub const empty = DeclBlock{
        .type = .text,
        .offset = 0,
    };
};

// TODO change base addr based on target (right now it just works on amd64)
const default_base_addr = 0x00200000;

pub const CallReloc = struct {
    caller: *Module.Decl,
    callee: *Module.Decl,
    offset_in_caller: usize,
};

pub const PtrWidth = enum { p32, p64 };

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*Plan9 {
    if (options.use_llvm)
        return error.LLVMBackendDoesNotSupportPlan9;
    const ptr_width: PtrWidth = switch (options.target.cpu.arch.ptrBitWidth()) {
        0...32 => .p32,
        33...64 => .p64,
        else => return error.UnsupportedELFArchitecture,
    };
    const self = try gpa.create(Plan9);
    self.* = .{
        .base = .{
            .tag = .plan9,
            .options = options,
            .allocator = gpa,
            .file = null,
        },
        .ptr_width = ptr_width,
    };
    return self;
}

pub fn updateDecl(self: *Plan9, module: *Module, decl: *Module.Decl) !void {
    _ = try self.decl_table.getOrPut(self.base.allocator, decl);
}

pub fn flush(self: *Plan9, comp: *Compilation) !void {
    assert(!self.base.options.use_lld);

    switch (self.base.options.effectiveOutputMode()) {
        .Exe => {},
        // plan9 object files are totally different
        .Obj => return error.TODOImplementPlan9Objs,
        .Lib => return error.TODOImplementWritingLibFiles,
    }
    return self.flushModule(comp);
}
pub fn flushModule(self: *Plan9, comp: *Compilation) !void {
    const module = self.base.options.module orelse return error.LinkingWithoutZigSourceUnimplemented;

    // generate the header
    self.hdr.magic = try aout.magicFromArch(self.base.options.target.cpu.arch);
    const file = self.base.file.?;
    try file.seekTo(self.headerSize());

    // temporary buffer
    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();
    {
        for (self.decl_table.keys()) |decl| {
            if (!decl.has_tv) continue;
            self.cur_decl = decl;
            const is_fn = (decl.ty.zigTypeTag() == .Fn);
            decl.link.plan9 = if (is_fn) .{
                .offset = @intCast(u32, self.text_buf.items.len),
                .type = .text,
            } else .{
                .offset = @intCast(u32, self.data_buf.items.len),
                .type = .data,
            };
            const res = try codegen.generateSymbol(&self.base, decl.srcLoc(), .{
                .ty = decl.ty,
                .val = decl.val,
            }, &code_buffer, .{ .none = {} });
            const code = switch (res) {
                .externally_managed => |x| x,
                .appended => code_buffer.items,
                .fail => |em| {
                    decl.analysis = .codegen_failure;
                    try module.failed_decls.put(module.gpa, decl, em);
                    // TODO try to do more decls
                    return;
                },
            };
            if (is_fn)
                try self.text_buf.appendSlice(self.base.allocator, code)
            else
                try self.data_buf.appendSlice(self.base.allocator, code);
            code_buffer.items.len = 0;
        }
    }
    try file.writeAll(self.text_buf.items);
    try file.writeAll(self.data_buf.items);
    try file.seekTo(0);
    self.hdr.text = @intCast(u32, self.text_buf.items.len);
    self.hdr.data = @intCast(u32, self.data_buf.items.len);
    self.hdr.pcsz = 0;
    self.hdr.spsz = 0;
    inline for (std.meta.fields(aout.ExecHdr)) |f| {
        try file.writer().writeIntBig(f.field_type, @field(self.hdr, f.name));
    }
}
pub fn freeDecl(self: *Plan9, decl: *Module.Decl) void {
    assert(self.decl_table.swapRemove(decl));
}

pub fn updateDeclExports(
    self: *Plan9,
    module: *Module,
    decl: *Module.Decl,
    exports: []const *Module.Export,
) !void {
    for (exports) |exp| {
        if (exp.options.section) |section_name| {
            if (!mem.eql(u8, section_name, ".text")) {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.count() + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Module.ErrorMsg.create(self.base.allocator, decl.srcLoc(), "plan9 does not support extra sections", .{}),
                );
                continue;
            }
        }
        if (std.mem.eql(u8, exp.options.name, "_start")) {
            std.debug.assert(decl.link.plan9.type == .text); // we tried to link a non-function as _start
            self.hdr.entry = Plan9.default_base_addr + self.headerSize() + decl.link.plan9.offset;
        }
        if (exp.link.plan9) |i| {
            const sym = &self.syms.items[i];
            sym.* = .{
                .value = decl.link.plan9.offset,
                .type = switch (decl.link.plan9.type) {
                    .text => .T,
                    .data => .D,
                },
                .name = decl.name,
            };
        } else {
            try self.syms.append(self.base.allocator, .{
                .value = decl.link.plan9.offset,
                .type = switch (decl.link.plan9.type) {
                    .text => .T,
                    .data => .D,
                },
                .name = decl.name,
            });
        }
    }
}
pub fn deinit(self: *Plan9) void {
    self.decl_table.deinit(self.base.allocator);
    self.call_relocs.deinit(self.base.allocator);
    self.syms.deinit(self.base.allocator);
    self.text_buf.deinit(self.base.allocator);
    self.data_buf.deinit(self.base.allocator);
}

pub const Export = ?usize;
pub const base_tag = .plan9;
pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*Plan9 {
    if (options.use_llvm)
        return error.LLVMBackendDoesNotSupportPlan9;
    assert(options.object_format == .plan9);
    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .truncate = false,
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options);
    errdefer self.base.destroy();

    self.base.file = file;
    return self;
}

pub fn addCallReloc(self: *Plan9, code: *std.ArrayList(u8), reloc: CallReloc) !void {
    try self.call_relocs.append(self.base.allocator, reloc);
    try code.writer().writeIntBig(u64, 0xdeadbeef);
}
