//! Turf's database (`col('shipments').findOne(...)`, as Turf-js wrote it), on zig-core's
//! mongo.db collections: filters, updates and pipelines are Zig literals or Vals, results Vals.

const std = @import("std");
const mongo = @import("mongo");
const bson = mongo.bson;
const val = mongo.val;
const Allocator = std.mem.Allocator;

pub const Coll = mongo.db.Coll;
pub const FindOpts = mongo.db.FindOpts;
pub const UpdateResult = mongo.db.UpdateResult;
pub const ReturnDoc = mongo.db.ReturnDoc;

pub var client: *mongo.Client = undefined;
pub var db_name: []const u8 = "Turf";

pub fn col(name: []const u8) Coll {
    return .{ .client = client, .db = db_name, .name = name };
}

/// Runs a command on Turf's database and returns the reply.
pub fn command(a: Allocator, cmd: anytype) !bson.Doc {
    return client.command(a, db_name, try val.toBson(a, cmd));
}

pub fn lastError() []const u8 {
    return client.lastError();
}
