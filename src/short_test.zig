const std = @import("std");
const opts = @import("opts");

test "short" {
    try std.testing.expect(opts.id < 1000);
}
