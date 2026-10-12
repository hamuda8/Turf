//! Minimal Code 128 (code set B) encoder producing an SVG, for tracking numbers on shipping labels
//! (src/barcode.js, same output).

const std = @import("std");

/// Bar/space widths for symbol values 0..106 (106 = stop, which has 7 elements).
const patterns = [_][]const u8{
    "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
    "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
    "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
    "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
    "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
    "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
    "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
    "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
    "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
    "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
    "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
};
const start_b = 104;
const stop = 106;

pub fn code128Svg(a: std.mem.Allocator, text: []const u8, o: struct { height: u32 = 70, module_width: u32 = 2 }) ![]const u8 {
    var values: std.ArrayList(u32) = .empty;
    try values.append(a, start_b);
    for (text) |c| {
        if (c < 32 or c > 126) return error.NotPrintableAscii;
        try values.append(a, c - 32);
    }
    var sum: u32 = 0;
    for (values.items, 0..) |v, i| sum += v * (if (i == 0) 1 else @as(u32, @intCast(i)));
    try values.append(a, sum % 103);
    try values.append(a, stop);

    var x: u32 = 10 * o.module_width;
    var rects: std.ArrayList(u8) = .empty;
    for (values.items) |v| {
        for (patterns[v], 0..) |wc, i| {
            const w = (wc - '0') * o.module_width;
            if (i % 2 == 0) try rects.print(a, "<rect x=\"{d}\" y=\"0\" width=\"{d}\" height=\"{d}\"/>", .{ x, w, o.height });
            x += w;
        }
    }
    const width = x + 10 * o.module_width;
    return std.fmt.allocPrint(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" role=\"img\" aria-label=\"{s}\"><g fill=\"#000\">{s}</g></svg>", .{ width, o.height, width, o.height, text, rects.items });
}
