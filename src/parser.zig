const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const diag_mod = @import("diag.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidNumber,
    OutOfMemory,
};

pub const max_field_number: i32 = 536_870_911;

pub const Parser = struct {
    arena: std.mem.Allocator,
    file_name: []const u8 = "<input>",
    diag: ?*diag_mod.Diagnostic = null,
    lex: lexer.Lexer,
    cur: lexer.Token,
    peek1: lexer.Token,
    peek2: lexer.Token,

    pub fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!ast.File {
        return parseWithDiag(arena, "<input>", src, null);
    }

    pub fn parseWithDiag(
        arena: std.mem.Allocator,
        file_name: []const u8,
        src: []const u8,
        diag: ?*diag_mod.Diagnostic,
    ) ParseError!ast.File {
        var lex = lexer.Lexer{ .src = src };
        const t0 = lex.next();
        const t1 = lex.next();
        const t2 = lex.next();
        var p = Parser{
            .arena = arena,
            .file_name = file_name,
            .diag = diag,
            .lex = lex,
            .cur = t0,
            .peek1 = t1,
            .peek2 = t2,
        };
        return p.parseFile();
    }

    fn advance(self: *Parser) lexer.Token {
        const prev = self.cur;
        self.cur = self.peek1;
        self.peek1 = self.peek2;
        self.peek2 = self.lex.next();
        return prev;
    }

    fn fail(self: *Parser, tok: lexer.Token, comptime fmt: []const u8, args: anytype, err: ParseError) ParseError {
        if (self.diag) |d| {
            d.* = .{
                .file = self.file_name,
                .line = tok.line,
                .col = tok.col,
                .message = std.fmt.allocPrint(self.arena, fmt, args) catch @errorName(err),
            };
        }
        return err;
    }

    fn expect(self: *Parser, kind: lexer.TokenKind) ParseError!lexer.Token {
        if (self.cur.kind != kind) {
            return self.fail(
                self.cur,
                "expected {s}, found '{s}'",
                .{ @tagName(kind), self.cur.text },
                error.UnexpectedToken,
            );
        }
        return self.advance();
    }

    fn isIdent(tok: lexer.Token, text: []const u8) bool {
        return tok.kind == .ident and std.mem.eql(u8, tok.text, text);
    }

    fn unescapeString(self: *Parser, raw: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c != '\\' or i + 1 >= raw.len) {
                try out.append(self.arena, c);
                i += 1;
                continue;
            }
            i += 1;
            const esc = raw[i];
            i += 1;
            switch (esc) {
                'a' => try out.append(self.arena, 0x07),
                'b' => try out.append(self.arena, 0x08),
                'f' => try out.append(self.arena, 0x0C),
                'n' => try out.append(self.arena, '\n'),
                'r' => try out.append(self.arena, '\r'),
                't' => try out.append(self.arena, '\t'),
                'v' => try out.append(self.arena, 0x0B),
                '\\', '\'', '"', '?' => try out.append(self.arena, esc),
                'x', 'X' => {
                    var val: u8 = 0;
                    var digits: usize = 0;
                    while (digits < 2 and i < raw.len and std.ascii.isHex(raw[i])) : (digits += 1) {
                        val = (val << 4) | (std.fmt.charToDigit(raw[i], 16) catch 0);
                        i += 1;
                    }
                    try out.append(self.arena, val);
                },
                '0'...'7' => {
                    var val: u16 = esc - '0';
                    var digits: usize = 1;
                    while (digits < 3 and i < raw.len and raw[i] >= '0' and raw[i] <= '7') : (digits += 1) {
                        val = (val << 3) | (raw[i] - '0');
                        i += 1;
                    }
                    try out.append(self.arena, @truncate(val));
                },
                else => try out.append(self.arena, esc),
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    /// Parses adjacent string literals (official proto grammar allows `"a" "b"`).
    fn parseStringConcat(self: *Parser) ParseError![]const u8 {
        const first = try self.unescapeString((try self.expect(.string)).text);
        if (self.cur.kind != .string) return first;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.arena, first);
        while (self.cur.kind == .string) {
            try buf.appendSlice(self.arena, try self.unescapeString(self.advance().text));
        }
        return try buf.toOwnedSlice(self.arena);
    }

    /// Parses `[.]ident(.ident)*`.
    fn parseQualifiedIdent(self: *Parser) ParseError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        if (self.cur.kind == .dot) {
            _ = self.advance();
            try buf.append(self.arena, '.');
        }
        try buf.appendSlice(self.arena, (try self.expect(.ident)).text);
        while (self.cur.kind == .dot) {
            _ = self.advance();
            try buf.append(self.arena, '.');
            try buf.appendSlice(self.arena, (try self.expect(.ident)).text);
        }
        return try buf.toOwnedSlice(self.arena);
    }

    /// Parses Protobuf integer literals: decimal, `0x` hex, and C-style leading-zero octal (`0777`).
    fn parseProtoInt(text: []const u8) ParseError!i64 {
        if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
            return std.fmt.parseInt(i64, text[2..], 16) catch return error.InvalidNumber;
        }
        if (text.len >= 2 and text[0] == '0') {
            return std.fmt.parseInt(i64, text[1..], 8) catch return error.InvalidNumber;
        }
        return std.fmt.parseInt(i64, text, 10) catch return error.InvalidNumber;
    }

    fn parseSignedI32(self: *Parser) ParseError!i32 {
        var neg = false;
        if (self.cur.kind == .minus) {
            neg = true;
            _ = self.advance();
        } else if (self.cur.kind == .plus) {
            _ = self.advance();
        }
        const tok = try self.expect(.number);
        const mag = try parseProtoInt(tok.text);
        const val = if (neg) -mag else mag;
        return std.math.cast(i32, val) orelse error.InvalidNumber;
    }

    fn parseFieldNumber(self: *Parser) ParseError!u29 {
        const tok = try self.expect(.number);
        const val = try parseProtoInt(tok.text);
        return std.math.cast(u29, val) orelse error.InvalidNumber;
    }

    fn parseOptionName(self: *Parser) ParseError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.cur.kind == .lparen) {
                _ = self.advance();
                try buf.append(self.arena, '(');
                try buf.appendSlice(self.arena, try self.parseQualifiedIdent());
                _ = try self.expect(.rparen);
                try buf.append(self.arena, ')');
            } else {
                try buf.appendSlice(self.arena, (try self.expect(.ident)).text);
            }
            if (self.cur.kind == .dot) {
                _ = self.advance();
                try buf.append(self.arena, '.');
            } else break;
        }
        return try buf.toOwnedSlice(self.arena);
    }

    /// Parses scalar, qualified enum/identifier (`pkg.Mode.FAST`), or aggregate `{ ... }` option values.
    fn parseOptionValue(self: *Parser) ParseError![]const u8 {
        if (self.cur.kind == .lbrace) {
            try self.skipBalanced(.lbrace, .rbrace);
            return "{...}";
        }
        if (self.cur.kind == .string) return self.parseStringConcat();
        if (self.cur.kind == .minus or self.cur.kind == .plus) {
            const sign = self.advance().text;
            if (self.cur.kind != .number and self.cur.kind != .ident) return error.UnexpectedToken;
            const num = self.advance().text;
            return try std.mem.concat(self.arena, u8, &.{ sign, num });
        }
        if (self.cur.kind == .number) {
            return self.advance().text;
        }
        if (self.cur.kind == .ident or self.cur.kind == .dot) {
            return self.parseQualifiedIdent();
        }
        return error.UnexpectedToken;
    }

    fn skipBalanced(self: *Parser, open: lexer.TokenKind, close: lexer.TokenKind) ParseError!void {
        _ = try self.expect(open);
        var depth: usize = 1;
        while (depth > 0 and self.cur.kind != .eof) {
            const tok = self.advance();
            if (tok.kind == open) depth += 1 else if (tok.kind == close) depth -= 1;
        }
        if (depth != 0) return error.UnexpectedToken;
    }

    fn parseFieldOptions(self: *Parser) ParseError![]ast.Option {
        if (self.cur.kind != .lbracket) return &.{};
        _ = self.advance();
        var opts: std.ArrayList(ast.Option) = .empty;
        while (self.cur.kind != .rbracket and self.cur.kind != .eof) {
            const name = try self.parseOptionName();
            _ = try self.expect(.eq);
            const val = try self.parseOptionValue();
            try opts.append(self.arena, .{ .name = name, .raw_value = val });
            if (self.cur.kind == .comma) _ = self.advance();
        }
        _ = try self.expect(.rbracket);
        return try opts.toOwnedSlice(self.arena);
    }

    fn parseOptionStmt(self: *Parser) ParseError!ast.Option {
        _ = self.advance(); // "option"
        const name = try self.parseOptionName();
        _ = try self.expect(.eq);
        const val = try self.parseOptionValue();
        _ = try self.expect(.semi);
        return .{ .name = name, .raw_value = val };
    }

    fn skipUntilSemi(self: *Parser) ParseError!void {
        while (self.cur.kind != .semi and self.cur.kind != .eof) {
            if (self.cur.kind == .lbrace) {
                try self.skipBalanced(.lbrace, .rbrace);
            } else {
                _ = self.advance();
            }
        }
        _ = try self.expect(.semi);
    }

    fn asciiLower(self: *Parser, text: []const u8) ParseError![]const u8 {
        const out = try self.arena.alloc(u8, text.len);
        for (text, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
        return out;
    }

    fn parseExtensionRanges(self: *Parser, ranges: *std.ArrayList(ast.ReservedRange)) ParseError!void {
        _ = self.advance(); // "extensions"
        while (self.cur.kind != .semi and self.cur.kind != .lbracket and self.cur.kind != .eof) {
            const start = try self.parseSignedI32();
            var end = start;
            if (isIdent(self.cur, "to")) {
                _ = self.advance();
                if (isIdent(self.cur, "max")) {
                    _ = self.advance();
                    end = max_field_number;
                } else {
                    end = try self.parseSignedI32();
                }
            }
            try ranges.append(self.arena, .{ .start = start, .end = end });
            if (self.cur.kind == .comma) {
                _ = self.advance();
            } else break;
        }
        _ = try self.parseFieldOptions();
        _ = try self.expect(.semi);
    }

    fn parseExtend(self: *Parser, sibling_messages: *std.ArrayList(ast.Message)) ParseError!ast.ExtensionDecl {
        _ = self.advance(); // "extend"
        const extendee = try self.parseQualifiedIdent();
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            try fields.append(self.arena, try self.parseFieldOrGroup(sibling_messages));
        }
        _ = try self.expect(.rbrace);
        return .{
            .extendee = extendee,
            .fields = try fields.toOwnedSlice(self.arena),
        };
    }

    fn parseMessageReserved(
        self: *Parser,
        ranges: *std.ArrayList(ast.ReservedRange),
        names: *std.ArrayList([]const u8),
    ) ParseError!void {
        _ = self.advance(); // "reserved"
        while (self.cur.kind != .semi and self.cur.kind != .eof) {
            if (self.cur.kind == .string) {
                try names.append(self.arena, try self.parseStringConcat());
            } else if (self.cur.kind == .ident) {
                // Editions allow bare identifier names in reserved statements.
                try names.append(self.arena, self.advance().text);
            } else {
                const start = try self.parseSignedI32();
                var end = start;
                if (isIdent(self.cur, "to")) {
                    _ = self.advance();
                    if (isIdent(self.cur, "max")) {
                        _ = self.advance();
                        end = max_field_number;
                    } else {
                        end = try self.parseSignedI32();
                    }
                }
                try ranges.append(self.arena, .{ .start = start, .end = end });
            }
            if (self.cur.kind == .comma) {
                _ = self.advance();
            } else break;
        }
        _ = try self.expect(.semi);
    }

    fn parseFile(self: *Parser) ParseError!ast.File {
        var syntax: ast.Syntax = .proto2;
        var package: ?[]const u8 = null;
        var imports: std.ArrayList([]const u8) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;
        var messages: std.ArrayList(ast.Message) = .empty;
        var enums: std.ArrayList(ast.Enum) = .empty;
        var services: std.ArrayList(ast.Service) = .empty;
        var public_imports: std.ArrayList(usize) = .empty;
        var extensions: std.ArrayList(ast.ExtensionDecl) = .empty;

        while (self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "syntax")) {
                _ = self.advance();
                _ = try self.expect(.eq);
                const s = try self.parseStringConcat();
                syntax = if (std.mem.eql(u8, s, "proto3")) .proto3 else .proto2;
                _ = try self.expect(.semi);
            } else if (isIdent(self.cur, "edition")) {
                _ = self.advance();
                _ = try self.expect(.eq);
                _ = try self.parseStringConcat();
                syntax = .edition;
                _ = try self.expect(.semi);
            } else if (isIdent(self.cur, "package")) {
                _ = self.advance();
                package = try self.parseQualifiedIdent();
                _ = try self.expect(.semi);
            } else if (isIdent(self.cur, "import")) {
                _ = self.advance();
                var is_public = false;
                if (isIdent(self.cur, "public")) {
                    is_public = true;
                    _ = self.advance();
                } else if (isIdent(self.cur, "weak")) {
                    _ = self.advance();
                }
                const idx = imports.items.len;
                try imports.append(self.arena, try self.parseStringConcat());
                if (is_public) try public_imports.append(self.arena, idx);
                _ = try self.expect(.semi);
            } else if (isIdent(self.cur, "option")) {
                try options.append(self.arena, try self.parseOptionStmt());
            } else if (isIdent(self.cur, "message")) {
                _ = self.advance();
                try messages.append(self.arena, try self.parseMessage());
            } else if (isIdent(self.cur, "enum")) {
                _ = self.advance();
                try enums.append(self.arena, try self.parseEnum());
            } else if (isIdent(self.cur, "service")) {
                _ = self.advance();
                try services.append(self.arena, try self.parseService());
            } else if (isIdent(self.cur, "extend")) {
                try extensions.append(self.arena, try self.parseExtend(&messages));
            } else {
                return error.UnexpectedToken;
            }
        }

        return .{
            .syntax = syntax,
            .package = package,
            .imports = try imports.toOwnedSlice(self.arena),
            .options = try options.toOwnedSlice(self.arena),
            .messages = try messages.toOwnedSlice(self.arena),
            .enums = try enums.toOwnedSlice(self.arena),
            .services = try services.toOwnedSlice(self.arena),
            .public_imports = try public_imports.toOwnedSlice(self.arena),
            .extensions = try extensions.toOwnedSlice(self.arena),
        };
    }

    fn parseEnum(self: *Parser) ParseError!ast.Enum {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var values: std.ArrayList(ast.EnumValue) = .empty;
        var allow_alias = false;

        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "option") and self.peek1.kind != .eq) {
                const opt = try self.parseOptionStmt();
                if (std.mem.eql(u8, opt.name, "allow_alias") and std.mem.eql(u8, opt.raw_value, "true")) {
                    allow_alias = true;
                }
            } else if (isIdent(self.cur, "reserved") and self.peek1.kind != .eq) {
                try self.skipUntilSemi();
            } else {
                const vname = (try self.expect(.ident)).text;
                _ = try self.expect(.eq);
                const num = try self.parseSignedI32();
                _ = try self.parseFieldOptions();
                _ = try self.expect(.semi);
                try values.append(self.arena, .{ .name = vname, .number = num });
            }
        }
        _ = try self.expect(.rbrace);
        return .{
            .name = name,
            .values = try values.toOwnedSlice(self.arena),
            .allow_alias = allow_alias,
        };
    }

    fn parseMessage(self: *Parser) ParseError!ast.Message {
        const name = (try self.expect(.ident)).text;
        return self.parseMessageBody(name);
    }

    fn parseMessageBody(self: *Parser, name: []const u8) ParseError!ast.Message {
        _ = try self.expect(.lbrace);

        var fields: std.ArrayList(ast.Field) = .empty;
        var maps: std.ArrayList(ast.MapField) = .empty;
        var oneofs: std.ArrayList(ast.Oneof) = .empty;
        var nested_messages: std.ArrayList(ast.Message) = .empty;
        var nested_enums: std.ArrayList(ast.Enum) = .empty;
        var reserved_ranges: std.ArrayList(ast.ReservedRange) = .empty;
        var reserved_names: std.ArrayList([]const u8) = .empty;
        var extension_ranges: std.ArrayList(ast.ReservedRange) = .empty;
        var extensions: std.ArrayList(ast.ExtensionDecl) = .empty;

        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "message") and self.peek1.kind == .ident and self.peek2.kind == .lbrace) {
                _ = self.advance();
                try nested_messages.append(self.arena, try self.parseMessage());
            } else if (isIdent(self.cur, "enum") and self.peek1.kind == .ident and self.peek2.kind == .lbrace) {
                _ = self.advance();
                try nested_enums.append(self.arena, try self.parseEnum());
            } else if (isIdent(self.cur, "oneof") and self.peek1.kind == .ident and self.peek2.kind == .lbrace) {
                _ = self.advance();
                try oneofs.append(self.arena, try self.parseOneof(&nested_messages));
            } else if (isIdent(self.cur, "map") and self.peek1.kind == .langle) {
                _ = self.advance();
                try maps.append(self.arena, try self.parseMapField());
            } else if (isIdent(self.cur, "option") and self.peek1.kind != .eq) {
                _ = try self.parseOptionStmt();
            } else if (isIdent(self.cur, "reserved") and self.peek2.kind != .eq) {
                try self.parseMessageReserved(&reserved_ranges, &reserved_names);
            } else if (isIdent(self.cur, "extensions") and self.peek1.kind == .number) {
                try self.parseExtensionRanges(&extension_ranges);
            } else if (isIdent(self.cur, "extend") and
                (self.peek1.kind == .ident or self.peek1.kind == .dot) and
                self.peek2.kind != .eq)
            {
                try extensions.append(self.arena, try self.parseExtend(&nested_messages));
            } else {
                try fields.append(self.arena, try self.parseFieldOrGroup(&nested_messages));
            }
        }
        _ = try self.expect(.rbrace);

        return .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.arena),
            .maps = try maps.toOwnedSlice(self.arena),
            .oneofs = try oneofs.toOwnedSlice(self.arena),
            .nested_messages = try nested_messages.toOwnedSlice(self.arena),
            .nested_enums = try nested_enums.toOwnedSlice(self.arena),
            .reserved_ranges = try reserved_ranges.toOwnedSlice(self.arena),
            .reserved_names = try reserved_names.toOwnedSlice(self.arena),
            .extension_ranges = try extension_ranges.toOwnedSlice(self.arena),
            .extensions = try extensions.toOwnedSlice(self.arena),
        };
    }

    fn parseFieldOrGroup(self: *Parser, sibling_messages: *std.ArrayList(ast.Message)) ParseError!ast.Field {
        var label: ast.FieldLabel = .implicit;
        if (isIdent(self.cur, "repeated") and self.peek1.kind != .eq) {
            label = .repeated;
            _ = self.advance();
        } else if (isIdent(self.cur, "optional") and self.peek1.kind != .eq) {
            label = .optional;
            _ = self.advance();
        } else if (isIdent(self.cur, "required") and self.peek1.kind != .eq) {
            label = .required;
            _ = self.advance();
        }

        // Proto2 group syntax: optional/required/repeated group Name = 1 [opts] { ... }
        if (isIdent(self.cur, "group") and self.peek1.kind == .ident and self.peek2.kind == .eq) {
            _ = self.advance();
            const group_name = (try self.expect(.ident)).text;
            _ = try self.expect(.eq);
            const number = try self.parseFieldNumber();
            const opts = try self.parseFieldOptions();
            const group_msg = try self.parseMessageBody(group_name);
            try sibling_messages.append(self.arena, group_msg);
            return .{
                .label = if (label == .implicit) .optional else label,
                .type_name = group_name,
                .name = try self.asciiLower(group_name),
                .number = number,
                .options = opts,
                .is_group = true,
            };
        }

        const type_name = try self.parseQualifiedIdent();
        const field_name = (try self.expect(.ident)).text;
        _ = try self.expect(.eq);
        const number = try self.parseFieldNumber();
        const opts = try self.parseFieldOptions();
        _ = try self.expect(.semi);

        return .{
            .label = label,
            .type_name = type_name,
            .name = field_name,
            .number = number,
            .options = opts,
        };
    }

    fn parseMapField(self: *Parser) ParseError!ast.MapField {
        _ = try self.expect(.langle);
        const key_type = (try self.expect(.ident)).text;
        _ = try self.expect(.comma);
        const value_type = try self.parseQualifiedIdent();
        _ = try self.expect(.rangle);
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.eq);
        const number = try self.parseFieldNumber();
        const opts = try self.parseFieldOptions();
        _ = try self.expect(.semi);

        return .{
            .key_type = key_type,
            .value_type = value_type,
            .name = name,
            .number = number,
            .options = opts,
        };
    }

    fn parseOneof(self: *Parser, sibling_messages: *std.ArrayList(ast.Message)) ParseError!ast.Oneof {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "option") and self.peek1.kind != .eq) {
                _ = try self.parseOptionStmt();
                continue;
            }
            if (isIdent(self.cur, "group") and self.peek1.kind == .ident and self.peek2.kind == .eq) {
                _ = self.advance();
                const group_name = (try self.expect(.ident)).text;
                _ = try self.expect(.eq);
                const number = try self.parseFieldNumber();
                const opts = try self.parseFieldOptions();
                const group_msg = try self.parseMessageBody(group_name);
                try sibling_messages.append(self.arena, group_msg);
                try fields.append(self.arena, .{
                    .label = .optional,
                    .type_name = group_name,
                    .name = try self.asciiLower(group_name),
                    .number = number,
                    .options = opts,
                    .is_group = true,
                });
                continue;
            }
            const type_name = try self.parseQualifiedIdent();
            const field_name = (try self.expect(.ident)).text;
            _ = try self.expect(.eq);
            const number = try self.parseFieldNumber();
            const opts = try self.parseFieldOptions();
            _ = try self.expect(.semi);
            try fields.append(self.arena, .{
                .label = .optional,
                .type_name = type_name,
                .name = field_name,
                .number = number,
                .options = opts,
            });
        }
        _ = try self.expect(.rbrace);
        return .{ .name = name, .fields = try fields.toOwnedSlice(self.arena) };
    }

    fn parseService(self: *Parser) ParseError!ast.Service {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var rpcs: std.ArrayList(ast.Rpc) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "option")) {
                _ = try self.parseOptionStmt();
                continue;
            }
            if (!isIdent(self.cur, "rpc")) return error.UnexpectedToken;
            _ = self.advance();
            const rpc_name = (try self.expect(.ident)).text;
            _ = try self.expect(.lparen);
            const req_stream = isIdent(self.cur, "stream");
            if (req_stream) _ = self.advance();
            const req_type = try self.parseQualifiedIdent();
            _ = try self.expect(.rparen);
            if (!isIdent(self.cur, "returns")) return error.UnexpectedToken;
            _ = self.advance();
            _ = try self.expect(.lparen);
            const res_stream = isIdent(self.cur, "stream");
            if (res_stream) _ = self.advance();
            const res_type = try self.parseQualifiedIdent();
            _ = try self.expect(.rparen);
            if (self.cur.kind == .lbrace) {
                try self.skipBalanced(.lbrace, .rbrace);
            } else {
                _ = try self.expect(.semi);
            }
            try rpcs.append(self.arena, .{
                .name = rpc_name,
                .req_type = req_type,
                .req_stream = req_stream,
                .res_type = res_type,
                .res_stream = res_stream,
            });
        }
        _ = try self.expect(.rbrace);
        return .{ .name = name, .rpcs = try rpcs.toOwnedSlice(self.arena) };
    }
};
