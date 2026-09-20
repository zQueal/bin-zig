//! The version this build reports — `bin -v/--version` prints it, and
//! `--debug` logs it at startup.
//!
//! Versioning starts at 1.0.0: the port has feature parity with the reference
//! (marcosnils/bin v0.29.3) plus its own fixes, so it is no longer a moving
//! "dev" build. Keep this string and `.version` in build.zig.zon in sync when
//! releasing.

pub const string = "1.0.3";
