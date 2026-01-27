//! Bin-zig library exports
const std = @import("std");

// Export core types and functions for library usage
pub const Config = @import("config.zig").Config;
pub const Binary = @import("config.zig").Binary;

pub const install = @import("install.zig").install;
pub const update = @import("update.zig").update;
pub const remove = @import("remove.zig").remove;
