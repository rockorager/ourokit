pub const icons = @import("icons.zig");
pub const applications = @import("applications.zig");

test {
    _ = icons;
    _ = applications;
    _ = @import("application_scan.zig");
}
