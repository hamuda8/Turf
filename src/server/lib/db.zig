//! MongoDB in the shape Turf-js uses it (`col('shipments').findOne(...)`): filters, updates and
//! pipelines are written as Zig literals or Vals and sent as they are, so MongoDB evaluates the
//! same queries the Node server sent. Results come back as Vals.
//!
//! Commands are built here rather than with zig-core's Collection helpers because Turf needs
//! options those do not have (partial indexes, findAndModify returning the old document,
//! distinct, count with a limit).

const std = @import("std");
const mongo = @import("mongo");
const bson = mongo.bson;
const val = @import("val.zig");
const Val = val.Val;
const Allocator = std.mem.Allocator;

pub var client: *mongo.Client = undefined;
pub var db_name: []const u8 = "Turf";

pub fn col(name: []const u8) Col {
    return .{ .name = name };
}

pub const FindOpts = struct {
    sort: ?Val = null,
    projection: ?Val = null,
    limit: ?i64 = null,
    skip: ?i64 = null,
};

pub const UpdateResult = struct {
    matched: i64,
    modified: i64,
    upserted_id: ?Val,
};

pub const ReturnDoc = enum { before, after };

pub const ModifyOpts = struct {
    sort: ?Val = null,
    projection: ?Val = null,
    upsert: bool = false,
    /// The Node driver's default is the document as it was before the update.
    returnDocument: ReturnDoc = .before,
};

/// Runs a command on Turf's database and returns the reply.
pub fn command(a: Allocator, cmd: anytype) !bson.Doc {
    const doc = try val.toBson(a, cmd);
    return client.command(a, db_name, doc);
}

pub fn lastError() []const u8 {
    return client.lastError();
}

pub const Col = struct {
    name: []const u8,

    fn run(c: Col, a: Allocator, b: *bson.Builder) !bson.Doc {
        _ = c;
        return client.command(a, db_name, try b.finish());
    }

    fn begin(c: Col, a: Allocator, cmd_name: []const u8) !bson.Builder {
        var b = try bson.Builder.init(a);
        try b.string(cmd_name, c.name);
        return b;
    }

    pub fn find(c: Col, a: Allocator, filter: anytype, o: FindOpts) ![]Val {
        var b = try c.begin(a, "find");
        try b.doc("filter", try val.toBson(a, filter));
        if (o.sort) |x| try b.doc("sort", try val.toBson(a, x));
        if (o.projection) |x| try b.doc("projection", try val.toBson(a, x));
        if (o.skip) |x| try b.int64("skip", x);
        if (o.limit) |x| if (x != 0) {
            // A negative limit in the Node driver means "one batch of |n|": same documents.
            try b.int64("limit", if (x < 0) -x else x);
        };
        return c.drain(a, try c.run(a, &b));
    }

    pub fn findOne(c: Col, a: Allocator, filter: anytype, o: FindOpts) !?Val {
        var opts = o;
        opts.limit = 1;
        const docs = try c.find(a, filter, opts);
        return if (docs.len > 0) docs[0] else null;
    }

    pub fn aggregate(c: Col, a: Allocator, pipeline: anytype) ![]Val {
        var b = try c.begin(a, "aggregate");
        const p = try val.from(a, pipeline);
        try b.beginArray("pipeline");
        for (p.items()) |stage| try val.writeBson(&b, "", stage);
        try b.end();
        try b.beginDoc("cursor");
        try b.end();
        return c.drain(a, try c.run(a, &b));
    }

    /// Every document of a cursor reply, fetching the remaining batches.
    fn drain(c: Col, a: Allocator, reply: bson.Doc) ![]Val {
        var out: std.ArrayList(Val) = .empty;
        var cur = reply.getDoc("cursor") orelse return error.BadReply;
        var batch = cur.getDoc("firstBatch") orelse return error.BadReply;
        while (true) {
            var it = batch.iterator();
            while (try it.next()) |e| switch (e.value) {
                .document => |d| try out.append(a, try val.fromBson(a, d)),
                else => {},
            };
            const cursor_id = (cur.get("id") orelse return error.BadReply).asInt() orelse 0;
            if (cursor_id == 0) break;
            var b = try bson.Builder.init(a);
            try b.int64("getMore", cursor_id);
            try b.string("collection", c.name);
            const r = try client.command(a, db_name, try b.finish());
            cur = r.getDoc("cursor") orelse return error.BadReply;
            batch = cur.getDoc("nextBatch") orelse return error.BadReply;
        }
        return out.items;
    }

    /// Inserts `doc`. Like the Node driver, an object without `_id` gets one added to it.
    pub fn insertOne(c: Col, a: Allocator, doc: anytype) !Val {
        const v = try val.from(a, doc);
        const ids = try c.insertMany(a, &.{v});
        return ids[0];
    }

    pub fn insertMany(c: Col, a: Allocator, docs: []const Val) ![]Val {
        const ids = try a.alloc(Val, docs.len);
        var b = try c.begin(a, "insert");
        try b.beginArray("documents");
        for (docs, ids) |d, *idv| {
            const o = d.asObj() orelse return error.NotAnObject;
            if (o.get("_id")) |existing| {
                idv.* = existing;
            } else {
                idv.* = .{ .oid = bson.ObjectId.generate(client.io) };
                try o.put("_id", idv.*);
            }
            // _id first, the way the server stores it.
            try b.beginDoc("");
            try val.writeBson(&b, "_id", idv.*);
            for (o.keys.items, o.vals.items) |k, x| if (!std.mem.eql(u8, k, "_id")) try val.writeBson(&b, k, x);
            try b.end();
        }
        try b.end();
        _ = try c.run(a, &b);
        return ids;
    }

    pub fn updateOne(c: Col, a: Allocator, filter: anytype, upd: anytype, o: struct { upsert: bool = false }) !UpdateResult {
        return c.update(a, filter, upd, o.upsert, false);
    }

    pub fn updateMany(c: Col, a: Allocator, filter: anytype, upd: anytype, o: struct { upsert: bool = false }) !UpdateResult {
        return c.update(a, filter, upd, o.upsert, true);
    }

    fn update(c: Col, a: Allocator, filter: anytype, upd: anytype, upsert: bool, multi: bool) !UpdateResult {
        var b = try c.begin(a, "update");
        try b.beginArray("updates");
        try b.beginDoc("");
        try b.doc("q", try val.toBson(a, filter));
        const u = try val.from(a, upd);
        // A pipeline update is an array of stages.
        if (u == .arr) {
            try val.writeBson(&b, "u", u);
        } else try b.doc("u", try val.toBson(a, u));
        try b.boolean("upsert", upsert);
        try b.boolean("multi", multi);
        try b.end();
        try b.end();
        const reply = try c.run(a, &b);
        const upserted = if (reply.getDoc("upserted")) |up| (if (up.getDoc("0")) |first| first.get("_id") else null) else null;
        return .{
            .matched = (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .modified = (reply.get("nModified") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .upserted_id = if (upserted) |x| try val.fromBsonValue(a, x) else null,
        };
    }

    pub fn deleteOne(c: Col, a: Allocator, filter: anytype) !i64 {
        return c.delete(a, filter, 1);
    }

    pub fn deleteMany(c: Col, a: Allocator, filter: anytype) !i64 {
        return c.delete(a, filter, 0);
    }

    fn delete(c: Col, a: Allocator, filter: anytype, limit: i32) !i64 {
        var b = try c.begin(a, "delete");
        try b.beginArray("deletes");
        try b.beginDoc("");
        try b.doc("q", try val.toBson(a, filter));
        try b.int32("limit", limit);
        try b.end();
        try b.end();
        const reply = try c.run(a, &b);
        return (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0;
    }

    /// countDocuments, optionally stopping at `limit`.
    pub fn count(c: Col, a: Allocator, filter: anytype, o: struct { limit: ?i64 = null }) !i64 {
        var b = try c.begin(a, "aggregate");
        try b.beginArray("pipeline");
        try b.beginDoc("");
        try b.doc("$match", try val.toBson(a, filter));
        try b.end();
        if (o.limit) |l| {
            try b.beginDoc("");
            try b.int64("$limit", l);
            try b.end();
        }
        try b.beginDoc("");
        try b.beginDoc("$group");
        try b.int32("_id", 1);
        try b.beginDoc("n");
        try b.int32("$sum", 1);
        try b.end();
        try b.end();
        try b.end();
        try b.end();
        try b.beginDoc("cursor");
        try b.end();
        const docs = try c.drain(a, try c.run(a, &b));
        if (docs.len == 0) return 0;
        return @intFromFloat(docs[0].n("n") orelse 0);
    }

    pub fn distinct(c: Col, a: Allocator, key: []const u8, filter: anytype) ![]Val {
        var b = try c.begin(a, "distinct");
        try b.string("key", key);
        try b.doc("query", try val.toBson(a, filter));
        const reply = try c.run(a, &b);
        var out: std.ArrayList(Val) = .empty;
        if (reply.getDoc("values")) |vals| {
            var it = vals.iterator();
            while (try it.next()) |e| try out.append(a, try val.fromBsonValue(a, e.value));
        }
        return out.items;
    }

    /// findOneAndUpdate: the document before (default) or after the update, or null.
    pub fn findOneAndUpdate(c: Col, a: Allocator, filter: anytype, upd: anytype, o: ModifyOpts) !?Val {
        var b = try c.begin(a, "findAndModify");
        try b.doc("query", try val.toBson(a, filter));
        const u = try val.from(a, upd);
        if (u == .arr) try val.writeBson(&b, "update", u) else try b.doc("update", try val.toBson(a, u));
        try b.boolean("new", o.returnDocument == .after);
        try b.boolean("upsert", o.upsert);
        if (o.sort) |x| try b.doc("sort", try val.toBson(a, x));
        if (o.projection) |x| try b.doc("fields", try val.toBson(a, x));
        const reply = try c.run(a, &b);
        return switch (reply.get("value") orelse return null) {
            .document => |d| try val.fromBson(a, d),
            else => null,
        };
    }

    /// createIndex with the options Turf uses (unique, sparse, partialFilterExpression, TTL, name).
    pub fn createIndex(c: Col, a: Allocator, keys: Val, options: Val) !void {
        var name: std.ArrayList(u8) = .empty;
        if (keys.asObj()) |o| for (o.keys.items, o.vals.items) |k, x| {
            if (name.items.len > 0) try name.append(a, '_');
            try name.appendSlice(a, k);
            try name.append(a, '_');
            try name.appendSlice(a, try val.toStr(a, x));
        };
        var b = try c.begin(a, "createIndexes");
        try b.beginArray("indexes");
        try b.beginDoc("");
        try val.writeBson(&b, "key", keys);
        try b.string("name", options.s("name") orelse name.items);
        if (options.asObj()) |o| for (o.keys.items, o.vals.items) |k, x| {
            if (!std.mem.eql(u8, k, "name")) try val.writeBson(&b, k, x);
        };
        try b.end();
        try b.end();
        _ = try c.run(a, &b);
    }
};
