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
    col: usize,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    line_start: usize = 0,

    fn currentCol(self: *const Lexer) usize {
        return (self.pos - self.line_start) + 1;
    }

    /// Returns `false` if an unterminated `/*` block comment reaches EOF.
    fn skipWhitespaceAndComments(self: *Lexer) bool {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                self.line_start = self.pos;
            } else if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                var closed = false;
                while (self.pos + 1 < self.src.len) : (self.pos += 1) {
                    if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        closed = true;
                        break;
                    }
                    if (self.src[self.pos] == '\n') {
                        self.line += 1;
                        self.line_start = self.pos + 1;
                    }
                }
                if (!closed) {
                    self.pos = self.src.len;
                    return false;
                }
            } else break;
        }
        return true;
    }

    pub fn next(self: *Lexer) Token {
        if (!self.skipWhitespaceAndComments()) {
            return .{ .kind = .invalid, .text = "/*", .line = self.line, .col = self.currentCol() };
        }
        const line = self.line;
        const col = self.currentCol();
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "", .line = line, .col = col };

        const start = self.pos;
        const c = self.src[self.pos];
        self.pos += 1;

        switch (c) {
            '{' => return .{ .kind = .lbrace, .text = "{", .line = line, .col = col },
            '}' => return .{ .kind = .rbrace, .text = "}", .line = line, .col = col },
            '(' => return .{ .kind = .lparen, .text = "(", .line = line, .col = col },
            ')' => return .{ .kind = .rparen, .text = ")", .line = line, .col = col },
            '[' => return .{ .kind = .lbracket, .text = "[", .line = line, .col = col },
            ']' => return .{ .kind = .rbracket, .text = "]", .line = line, .col = col },
            '<' => return .{ .kind = .langle, .text = "<", .line = line, .col = col },
            '>' => return .{ .kind = .rangle, .text = ">", .line = line, .col = col },
            '=' => return .{ .kind = .eq, .text = "=", .line = line, .col = col },
            ';' => return .{ .kind = .semi, .text = ";", .line = line, .col = col },
            ',' => return .{ .kind = .comma, .text = ",", .line = line, .col = col },
            ':' => return .{ .kind = .colon, .text = ":", .line = line, .col = col },
            '-' => return .{ .kind = .minus, .text = "-", .line = line, .col = col },
            '+' => return .{ .kind = .plus, .text = "+", .line = line, .col = col },
            '.' => {
                if (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                    self.scanNumberTail();
                    return .{ .kind = .number, .text = self.src[start..self.pos], .line = line, .col = col };
                }
                return .{ .kind = .dot, .text = ".", .line = line, .col = col };
            },
            '"', '\'' => {
                const quote = c;
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    self.pos += 1;
                    if (ch == '\n') {
                        self.line += 1;
                        self.line_start = self.pos;
                    } else if (ch == '\\' and self.pos < self.src.len) {
                        if (self.src[self.pos] == '\n') {
                            self.line += 1;
                            self.line_start = self.pos + 1;
                        }
                        self.pos += 1;
                    } else if (ch == quote) {
                        return .{ .kind = .string, .text = self.src[start + 1 .. self.pos - 1], .line = line, .col = col };
                    }
                }
                return .{ .kind = .invalid, .text = self.src[start..self.pos], .line = line, .col = col };
            },
            else => {},
        }

        if (std.ascii.isDigit(c)) {
            self.scanNumberTail();
            return .{ .kind = .number, .text = self.src[start..self.pos], .line = line, .col = col };
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.src.len) : (self.pos += 1) {
                const ch = self.src[self.pos];
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
            }
            return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line, .col = col };
        }

        return .{ .kind = .invalid, .text = self.src[start..self.pos], .line = line, .col = col };
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
