const std = @import("std");

pub const TokenKind = enum {
    ident,
    number,
    string,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    langle,
    rangle,
    eq,
    semi,
    comma,
    colon,
    dot,
    minus,
    plus,
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: usize,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.line += 1;
                self.pos += 1;
            } else if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.src.len and
                    !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/')) : (self.pos += 1)
                {
                    if (self.src[self.pos] == '\n') self.line += 1;
                }
                if (self.pos + 1 < self.src.len) self.pos += 2;
            } else break;
        }
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        const line = self.line;
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "", .line = line };

        const start = self.pos;
        const c = self.src[self.pos];
        self.pos += 1;

        switch (c) {
            '{' => return .{ .kind = .lbrace, .text = "{", .line = line },
            '}' => return .{ .kind = .rbrace, .text = "}", .line = line },
            '(' => return .{ .kind = .lparen, .text = "(", .line = line },
            ')' => return .{ .kind = .rparen, .text = ")", .line = line },
            '[' => return .{ .kind = .lbracket, .text = "[", .line = line },
            ']' => return .{ .kind = .rbracket, .text = "]", .line = line },
            '<' => return .{ .kind = .langle, .text = "<", .line = line },
            '>' => return .{ .kind = .rangle, .text = ">", .line = line },
            '=' => return .{ .kind = .eq, .text = "=", .line = line },
            ';' => return .{ .kind = .semi, .text = ";", .line = line },
            ',' => return .{ .kind = .comma, .text = ",", .line = line },
            ':' => return .{ .kind = .colon, .text = ":", .line = line },
            '-' => return .{ .kind = .minus, .text = "-", .line = line },
            '+' => return .{ .kind = .plus, .text = "+", .line = line },
            '.' => {
                // Float starting with '.' like .5
                if (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                    self.scanNumberTail();
                    return .{ .kind = .number, .text = self.src[start..self.pos], .line = line };
                }
                return .{ .kind = .dot, .text = ".", .line = line };
            },
            '"', '\'' => {
                const quote = c;
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    self.pos += 1;
                    if (ch == '\\' and self.pos < self.src.len) {
                        self.pos += 1;
                    } else if (ch == quote) {
                        return .{ .kind = .string, .text = self.src[start + 1 .. self.pos - 1], .line = line };
                    }
                }
                return .{ .kind = .invalid, .text = self.src[start..self.pos], .line = line };
            },
            else => {},
        }

        if (std.ascii.isDigit(c)) {
            self.scanNumberTail();
            return .{ .kind = .number, .text = self.src[start..self.pos], .line = line };
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.src.len) : (self.pos += 1) {
                const ch = self.src[self.pos];
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
            }
            return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line };
        }

        return .{ .kind = .invalid, .text = self.src[start..self.pos], .line = line };
    }

    fn scanNumberTail(self: *Lexer) void {
        if (self.pos < self.src.len and (self.src[self.pos] == 'x' or self.src[self.pos] == 'X')) {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) : (self.pos += 1) {}
            return;
        }
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (std.ascii.isDigit(ch) or ch == '.') {
                self.pos += 1;
            } else if (ch == 'e' or ch == 'E') {
                self.pos += 1;
                if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                    self.pos += 1;
                }
            } else break;
        }
    }
};
