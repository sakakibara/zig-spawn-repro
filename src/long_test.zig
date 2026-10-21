const std = @import("std");
const opts = @import("opts");

test "long" {
    try std.testing.io.sleep(.fromSeconds(opts.secs), .awake);
}
