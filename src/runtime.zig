//! Downstream runtime compatibility, independent of package/release naming.
//! Increment api_level for new supported Lua or development-control contracts;
//! document each level in docs/runtime.md and retain earlier levels' contracts.
pub const api_level = 3;
pub const version = "0.1.0";
pub const revision = @import("ourokit_build_options").revision;
