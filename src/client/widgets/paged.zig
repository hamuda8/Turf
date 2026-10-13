//! A list that grows with "Load more" (shipments, audit): the first page is a data slot (it
//! reloads in place), later pages are kept here in their own memory. The page frees it in its
//! `leave`.

const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json.zig");

const V = json.V;

pub const Paged = struct {
    arena: ?std.heap.ArenaAllocator = null,
    extra: std.ArrayList(V) = .empty,

    /// Drops the pages after the first (a new filter, a reload).
    pub fn reset(p: *Paged) void {
        if (p.arena) |*a| a.deinit();
        p.arena = null;
        p.extra = .empty;
    }

    /// Adds the rows of a later page: the array at `path` of the JSON `body` ("" for a bare array).
    pub fn add(p: *Paged, body: []const u8, path: []const u8) void {
        if (p.arena == null) p.arena = .init(core.gpa);
        const a = p.arena.?.allocator();
        const v = json.parse(a, body) orelse return;
        for (json.arr(v, path)) |row| p.extra.append(a, row) catch {};
    }

    /// The rows of the first page and the later ones, in order (in `a`).
    pub fn rows(p: *const Paged, a: std.mem.Allocator, first: ?V, path: []const u8) []const V {
        var out: std.ArrayList(V) = .empty;
        out.appendSlice(a, json.arr(first, path)) catch {};
        out.appendSlice(a, p.extra.items) catch {};
        return out.items;
    }

    pub fn deinit(p: *Paged) void {
        p.reset();
    }
};
