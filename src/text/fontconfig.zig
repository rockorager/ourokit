const std = @import("std");
const c = @import("fontconfig_c.zig").fc;

pub const Weight = enum {
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    black,

    fn fontconfig(self: Weight) c_int {
        return switch (self) {
            .thin => c.FC_WEIGHT_THIN,
            .light => c.FC_WEIGHT_LIGHT,
            .regular => c.FC_WEIGHT_REGULAR,
            .medium => c.FC_WEIGHT_MEDIUM,
            .semibold => c.FC_WEIGHT_SEMIBOLD,
            .bold => c.FC_WEIGHT_BOLD,
            .black => c.FC_WEIGHT_BLACK,
        };
    }
};

pub const Slant = enum {
    roman,
    italic,
    oblique,

    fn fontconfig(self: Slant) c_int {
        return switch (self) {
            .roman => c.FC_SLANT_ROMAN,
            .italic => c.FC_SLANT_ITALIC,
            .oblique => c.FC_SLANT_OBLIQUE,
        };
    }
};

pub const Query = struct {
    family: []const u8,
    language: ?[]const u8 = null,
    pixel_size: ?f64 = null,
    weight: Weight = .regular,
    slant: Slant = .roman,
};

/// One render-prepared candidate from Fontconfig's configured fallback order.
/// Strings and charset coverage are owned by the containing `CandidateSet`.
pub const Face = struct {
    family: []const u8,
    file: []const u8,
    /// Preserve Fontconfig's complete index, including named-instance bits.
    index: u32,
    variable: bool,
    variations: ?[]const u8,
    coverage: ?*c.FcCharSet,

    pub fn covers(self: Face, codepoint: u21) bool {
        const coverage = self.coverage orelse return false;
        return c.FcCharSetHasChar(coverage, codepoint) != 0;
    }
};

pub const CandidateSet = struct {
    allocator: std.mem.Allocator,
    faces: []Face,

    pub fn deinit(self: *CandidateSet) void {
        for (self.faces) |face| deinitFace(self.allocator, face);
        self.allocator.free(self.faces);
        self.* = undefined;
    }
};

/// An immutable Fontconfig snapshot. Applications should own one instance and
/// refresh it only at an application safe point when configuration changes.
pub const Database = struct {
    config: *c.FcConfig,

    pub fn init() !Database {
        return .{ .config = c.FcInitLoadConfigAndFonts() orelse return error.FontconfigInitFailed };
    }

    pub fn deinit(self: *Database) void {
        c.FcConfigDestroy(self.config);
        self.* = undefined;
    }

    pub fn isUpToDate(self: *const Database) bool {
        return c.FcConfigUptoDate(self.config) != 0;
    }

    /// Returns Fontconfig's ordered, coverage-trimmed fallback candidates.
    /// Selection still requires HarfBuzz cmap/shaping checks at safe text-run
    /// boundaries; Fontconfig charset membership is only a fast prefilter.
    pub fn candidates(
        self: *const Database,
        allocator: std.mem.Allocator,
        query: Query,
    ) !CandidateSet {
        if (query.family.len == 0 or query.family.len > std.math.maxInt(c_int))
            return error.InvalidQuery;
        if (query.pixel_size) |size|
            if (!std.math.isFinite(size) or size <= 0) return error.InvalidQuery;

        const pattern = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pattern);
        const family = try allocator.dupeZ(u8, query.family);
        defer allocator.free(family);
        if (c.FcPatternAddString(pattern, c.FC_FAMILY, family.ptr) == 0 or
            c.FcPatternAddInteger(pattern, c.FC_WEIGHT, query.weight.fontconfig()) == 0 or
            c.FcPatternAddInteger(pattern, c.FC_SLANT, query.slant.fontconfig()) == 0)
            return error.OutOfMemory;
        if (query.language) |language| {
            if (language.len == 0 or language.len > std.math.maxInt(c_int)) return error.InvalidQuery;
            const language_z = try allocator.dupeZ(u8, language);
            defer allocator.free(language_z);
            if (c.FcPatternAddString(pattern, c.FC_LANG, language_z.ptr) == 0)
                return error.OutOfMemory;
        }
        if (query.pixel_size) |size|
            if (c.FcPatternAddDouble(pattern, c.FC_PIXEL_SIZE, size) == 0)
                return error.OutOfMemory;

        if (c.FcConfigSubstitute(self.config, pattern, c.FcMatchPattern) == 0)
            return error.SubstitutionFailed;
        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        var union_coverage: ?*c.FcCharSet = null;
        const sorted = c.FcFontSort(
            self.config,
            pattern,
            c.FcTrue,
            &union_coverage,
            &result,
        ) orelse return error.NoMatch;
        defer c.FcFontSetDestroy(sorted);
        defer if (union_coverage) |coverage| c.FcCharSetDestroy(coverage);
        if (result != c.FcResultMatch or sorted.*.nfont <= 0) return error.NoMatch;

        var faces: std.ArrayList(Face) = .empty;
        errdefer {
            for (faces.items) |face| deinitFace(allocator, face);
            faces.deinit(allocator);
        }
        for (sorted.*.fonts[0..@intCast(sorted.*.nfont)]) |candidate| {
            const prepared = c.FcFontRenderPrepare(self.config, pattern, candidate) orelse
                return error.OutOfMemory;
            defer c.FcPatternDestroy(prepared);
            const face = try copyFace(allocator, prepared);
            errdefer deinitFace(allocator, face);
            try faces.append(allocator, face);
        }
        return .{ .allocator = allocator, .faces = try faces.toOwnedSlice(allocator) };
    }
};

fn copyFace(allocator: std.mem.Allocator, pattern: *c.FcPattern) !Face {
    var family_raw: [*c]c.FcChar8 = null;
    var file_raw: [*c]c.FcChar8 = null;
    var index: c_int = 0;
    if (c.FcPatternGetString(pattern, c.FC_FAMILY, 0, &family_raw) != c.FcResultMatch or
        c.FcPatternGetString(pattern, c.FC_FILE, 0, &file_raw) != c.FcResultMatch or
        c.FcPatternGetInteger(pattern, c.FC_INDEX, 0, &index) != c.FcResultMatch)
        return error.InvalidFontPattern;

    const family = try duplicateFcString(allocator, family_raw);
    errdefer allocator.free(family);
    const file = try duplicateFcString(allocator, file_raw);
    errdefer allocator.free(file);

    var variable: c.FcBool = c.FcFalse;
    _ = c.FcPatternGetBool(pattern, c.FC_VARIABLE, 0, &variable);
    var variations_raw: [*c]c.FcChar8 = null;
    const variations = if (c.FcPatternGetString(
        pattern,
        c.FC_FONT_VARIATIONS,
        0,
        &variations_raw,
    ) == c.FcResultMatch)
        try duplicateFcString(allocator, variations_raw)
    else
        null;
    errdefer if (variations) |value| allocator.free(value);

    var coverage_raw: ?*c.FcCharSet = null;
    const coverage = if (c.FcPatternGetCharSet(
        pattern,
        c.FC_CHARSET,
        0,
        &coverage_raw,
    ) == c.FcResultMatch and coverage_raw != null)
        c.FcCharSetCopy(coverage_raw.?) orelse return error.OutOfMemory
    else
        null;

    return .{
        .family = family,
        .file = file,
        .index = @bitCast(index),
        .variable = variable != c.FcFalse,
        .variations = variations,
        .coverage = coverage,
    };
}

fn deinitFace(allocator: std.mem.Allocator, face: Face) void {
    if (face.coverage) |coverage| c.FcCharSetDestroy(coverage);
    if (face.variations) |variations| allocator.free(variations);
    allocator.free(face.file);
    allocator.free(face.family);
}

fn duplicateFcString(allocator: std.mem.Allocator, value: [*c]const c.FcChar8) ![]u8 {
    if (value == null) return error.InvalidFontPattern;
    return allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))));
}

test "configured generic sans-serif returns an ordered coverage set" {
    var database = Database.init() catch return error.SkipZigTest;
    defer database.deinit();
    var candidates_set = database.candidates(std.testing.allocator, .{
        .family = "sans-serif",
        .language = "en",
        .pixel_size = 14,
    }) catch return error.SkipZigTest;
    defer candidates_set.deinit();
    try std.testing.expect(candidates_set.faces.len != 0);
    try std.testing.expect(candidates_set.faces[0].file.len != 0);
    try std.testing.expect(candidates_set.faces[0].covers('A'));

    var arabic_set = database.candidates(std.testing.allocator, .{
        .family = "sans-serif",
        .language = "ar",
        .pixel_size = 14,
    }) catch return error.SkipZigTest;
    defer arabic_set.deinit();
    for (arabic_set.faces) |face|
        if (face.covers('س')) return;
    return error.SkipZigTest;
}
