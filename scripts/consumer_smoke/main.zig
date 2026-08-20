const std = @import("std");
const csar = @import("csar");

pub fn main(init: std.process.Init) !void {
    const pts = [_][3]f64{ .{ 1, 0, 0 }, .{ 0.9, 0.1, 0 }, .{ 0.9, 0, 0.1 }, .{ 0.9, 0.1, 0.1 } };
    var o = try csar.solve(init.gpa, &pts, .{});
    defer o.deinit();
    if (o != .converged) return error.SmokeDidNotConverge;
    std.debug.print("consumer-smoke: ok ({t})\n", .{o});
}
