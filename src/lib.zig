//! The 1Color (BRC-162) token library: the output parsers and the token
//! rules, the module `1color` of the skein-1color package. Only `std`.
//!
//!   brc162   the BRC-162 binary output parser: `<id | OP_0> <amount | OP_0> OP_2DROP [<payload> OP_DROP] <lock>`
//!   brc161   the BRC-161 (BSV-21 JSON, legacy) inscription parser
//!   bsv21    the BSV-21 rules for one token over one parsed transaction (both forms)
//!   name     topic and lookup names (BRC-207): `tm_color_<assetId>`, `ls_color_<assetId>`, the
//!            asset id `<txid>_<vout>` (`<txid>_0` at output 0)
//!   token    the topic's verdict: the rules, nothing else
//!
//! The topic manager (src/color_topic.zig) and the lookup service
//! (src/color_lookup.zig) are built on it; an application's own programs
//! (an AMM's lookup and validator) depend on it by URL+hash.
pub const brc162 = @import("brc162.zig");
pub const brc161 = @import("brc161.zig");
pub const bsv21 = @import("bsv21.zig");
pub const name = @import("name.zig");
pub const token = @import("token.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
