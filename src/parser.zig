const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidNumber,
    OutOfMemory,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    lex: lexer.Lexer,
    cur: lexer.Token,
    peek_tok: lexer.Token,

    pub fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!ast.File {
        var lex = lexer.Lexer{ .src = src };
        const first = lex.next();
        const second = lex.next();
        var p = Parser{
            .arena = arena,
            .lex = lex,
            .cur = first,
            .peek_tok = second,
        };
        return p.parseFile();
    }

    fn advance(self: *Parser) lexer.Token {
        const prev = self.cur;
        self.cur = self.peek_tok;
        self.peek_tok = self.lex.next();
        return prev;
    }

    fn expect(self: *Parser, kind: lexer.TokenKind) ParseError!lexer.Token {
        if (self.cur.kind != kind) return error.UnexpectedToken;
        return self.advance();
    }

    fn isIdent(tok: lexer.Token, text: []const u8) bool {
        return tok.kind == .ident and std.mem.eql(u8, tok.text, text);
    }

    /// Parses adjacent string literals (official proto grammar allows `"a" "b"`).
    fn parseStringConcat(self: *Parser) ParseError![]const u8 {
        const first = try self.expect(.string);
        if (self.cur.kind != .string) return first.text;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.arena, first.text);
        while (self.cur.kind == .string) {
            try buf.appendSlice(self.arena, self.advance().text);
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

    fn parseSignedI32(self: *Parser) ParseError!i32 {
        var neg = false;
        if (self.cur.kind == .minus) {
            neg = true;
            _ = self.advance();
        } else if (self.cur.kind == .plus) {
            _ = self.advance();
        }
        const tok = try self.expect(.number);
        const mag = std.fmt.parseInt(i64, tok.text, 0) catch return error.InvalidNumber;
        const val = if (neg) -mag else mag;
        return std.math.cast(i32, val) orelse error.InvalidNumber;
    }

    fn parseFieldNumber(self: *Parser) ParseError!u29 {
        const tok = try self.expect(.number);
        return std.fmt.parseInt(u29, tok.text, 0) catch return error.InvalidNumber;
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

    /// Parses scalar or aggregate `{ ... }` option values.
    fn parseOptionValue(self: *Parser) ParseError![]const u8 {
        if (self.cur.kind == .lbrace) {
            try self.skipBalanced(.lbrace, .rbrace);
            return "{...}";
        }
        if (self.cur.kind == .string) return self.parseStringConcat();
        if (self.cur.kind == .minus or self.cur.kind == .plus) {
            const sign = self.advance().text;
            const num = self.advance().text;
            return try std.mem.concat(self.arena, u8, &.{ sign, num });
        }
        if (self.cur.kind == .ident or self.cur.kind == .number) {
            return self.advance().text;
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

    fn parseFile(self: *Parser) ParseError!ast.File {
        var syntax: ast.Syntax = .proto2;
        var package: ?[]const u8 = null;
        var imports: std.ArrayList([]const u8) = .empty;
        var options: std.ArrayList(ast.Option) = .empty;
        var messages: std.ArrayList(ast.Message) = .empty;
        var enums: std.ArrayList(ast.Enum) = .empty;
        var services: std.ArrayList(ast.Service) = .empty;
        var public_imports: std.ArrayList(usize) = .empty;

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
                _ = self.advance();
                _ = try self.parseQualifiedIdent();
                try self.skipBalanced(.lbrace, .rbrace);
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
        };
    }

    fn parseEnum(self: *Parser) ParseError!ast.Enum {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var values: std.ArrayList(ast.EnumValue) = .empty;

        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "option") and self.peek_tok.kind != .eq) {
                _ = try self.parseOptionStmt();
            } else if (isIdent(self.cur, "reserved") and self.peek_tok.kind != .eq) {
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
        return .{ .name = name, .values = try values.toOwnedSlice(self.arena) };
    }

    fn parseMessage(self: *Parser) ParseError!ast.Message {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);

        var fields: std.ArrayList(ast.Field) = .empty;
        var maps: std.ArrayList(ast.MapField) = .empty;
        var oneofs: std.ArrayList(ast.Oneof) = .empty;
        var nested_messages: std.ArrayList(ast.Message) = .empty;
        var nested_enums: std.ArrayList(ast.Enum) = .empty;

        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "message") and self.peek_tok.kind == .ident) {
                _ = self.advance();
                try nested_messages.append(self.arena, try self.parseMessage());
            } else if (isIdent(self.cur, "enum") and self.peek_tok.kind == .ident) {
                _ = self.advance();
                try nested_enums.append(self.arena, try self.parseEnum());
            } else if (isIdent(self.cur, "oneof") and self.peek_tok.kind == .ident) {
                _ = self.advance();
                try oneofs.append(self.arena, try self.parseOneof());
            } else if (isIdent(self.cur, "map") and self.peek_tok.kind == .langle) {
                _ = self.advance();
                try maps.append(self.arena, try self.parseMapField());
            } else if (isIdent(self.cur, "option")) {
                _ = try self.parseOptionStmt();
            } else if (isIdent(self.cur, "reserved") or isIdent(self.cur, "extensions")) {
                try self.skipUntilSemi();
            } else if (isIdent(self.cur, "extend")) {
                _ = self.advance();
                _ = try self.parseQualifiedIdent();
                try self.skipBalanced(.lbrace, .rbrace);
            } else {
                if (try self.parseFieldOrGroup()) |f| {
                    try fields.append(self.arena, f);
                }
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
        };
    }

    fn parseFieldOrGroup(self: *Parser) ParseError!?ast.Field {
        var label: ast.FieldLabel = .implicit;
        if (isIdent(self.cur, "repeated")) {
            label = .repeated;
            _ = self.advance();
        } else if (isIdent(self.cur, "optional")) {
            label = .optional;
            _ = self.advance();
        } else if (isIdent(self.cur, "required")) {
            label = .required;
            _ = self.advance();
        }

        // Proto2 group syntax: optional group Name = 1 { ... }
        if (isIdent(self.cur, "group") and self.peek_tok.kind == .ident) {
            _ = self.advance();
            _ = try self.expect(.ident);
            _ = try self.expect(.eq);
            _ = try self.parseFieldNumber();
            _ = try self.parseFieldOptions();
            try self.skipBalanced(.lbrace, .rbrace);
            return null;
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

    fn parseOneof(self: *Parser) ParseError!ast.Oneof {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .semi) {
                _ = self.advance();
                continue;
            }
            if (isIdent(self.cur, "option")) {
                _ = try self.parseOptionStmt();
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
