const std = @import("std");
const hash = std.crypto.hash;
const Blake3 = hash.Blake3;

const BASE32_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn encode_base32(data: u64, buf: []u8) void {
    std.debug.assert(buf.len == 13);
    inline for (0..13) |ix| {
        const i: u6 = @intCast(ix);
        const shift: u6 = 60 - (i * 5);
        const index: u8 = @intCast((data >> shift) & 0x1F);
        buf[ix] = BASE32_ALPHABET[index];
    }
}

test "encoding" {
    const testing = std.testing;

    var buf: [13]u8 = undefined;
    encode_base32(0, &buf);
    try testing.expectEqualStrings("0000000000000", &buf);
    encode_base32(0x1F, &buf);
    try testing.expectEqualStrings("000000000000Z", &buf);
    encode_base32(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualStrings("FZZZZZZZZZZZZ", &buf);
}

pub fn fingerprint(data: []u8, out: []u8) void {
    std.debug.assert(out.len == 13);
    var buf: [8]u8 = undefined;
    Blake3.hash(data, &buf, .{});
    const hashed = std.mem.readInt(u64, &buf, .big);
    encode_base32(hashed, out);
}
