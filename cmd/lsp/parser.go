package main

import (
	"fmt"
	"strings"
)

// ---------------------------------------------------------------------------
// Parse result — all symbols extracted from a .chasm file
// ---------------------------------------------------------------------------

type diagEntry struct {
	rng Range
	msg string
}

type fnInfo struct {
	name      string
	sig       string
	doc       string
	defRange  Range
	bodyRange Range
	isPrivate bool
	params    []paramInfo
	retType   string
}

type paramInfo struct {
	name string
	typ  string
}

type attrInfo struct {
	name     string
	typ      string
	lifetime string
	decl     string
	doc      string
	defRange Range
}

type structInfo struct {
	name      string
	decl      string
	defRange  Range
	bodyRange Range
	fields    []fieldInfo
}

type fieldInfo struct {
	name string
	typ  string
}

type enumInfo struct {
	name      string
	decl      string
	defRange  Range
	bodyRange Range
	variants  []string
}

type parseResult struct {
	errors     []diagEntry
	warnings   []diagEntry
	fns        map[string]*fnInfo
	fnList     []*fnInfo
	attrs      map[string]*attrInfo
	attrList   []*attrInfo
	structs    map[string]*structInfo
	structList []*structInfo
	enums      map[string]*enumInfo
	enumList   []*enumInfo
	imports    []importInfo
}

type importInfo struct {
	alias        string // basename without extension, e.g. "math"
	path         string // raw import path from source
	resolvedPath string // absolute filesystem path
	symbols      *parseResult
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

type tokenKind int

const (
	tokEOF tokenKind = iota
	tokIdent
	tokAtIdent // @name
	tokInt
	tokFloat
	tokString
	tokAtom // :name
	tokNewline
	tokComma
	tokDot
	tokDotDot
	tokColon
	tokColonColon
	tokEq
	tokArrow // ->
	tokPipe  // |>
	tokLParen
	tokRParen
	tokLBracket
	tokRBracket
	tokLBrace
	tokRBrace
	tokHash // # (comment)
	tokOp   // +,-,*,/,<,>,<=,>=,==,!=,!
)

type token struct {
	kind tokenKind
	text string
	line int
	col  int
}

type lexer struct {
	src  []rune
	pos  int
	line int
	col  int
}

func newLexer(src string) *lexer {
	return &lexer{src: []rune(src), line: 0, col: 0}
}

func (l *lexer) peek() rune {
	if l.pos >= len(l.src) {
		return 0
	}
	return l.src[l.pos]
}

func (l *lexer) peek2() rune {
	if l.pos+1 >= len(l.src) {
		return 0
	}
	return l.src[l.pos+1]
}

func (l *lexer) advance() rune {
	if l.pos >= len(l.src) {
		return 0
	}
	c := l.src[l.pos]
	l.pos++
	if c == '\n' {
		l.line++
		l.col = 0
	} else {
		l.col++
	}
	return c
}

func (l *lexer) next() token {
	// Skip spaces (not newlines)
	for l.peek() == ' ' || l.peek() == '\t' || l.peek() == '\r' {
		l.advance()
	}
	startLine := l.line
	startCol := l.col

	c := l.peek()
	if c == 0 {
		return token{tokEOF, "", startLine, startCol}
	}

	// Newline
	if c == '\n' {
		l.advance()
		return token{tokNewline, "\n", startLine, startCol}
	}

	// Comment
	if c == '#' {
		for l.peek() != '\n' && l.peek() != 0 {
			l.advance()
		}
		return l.next()
	}

	// String
	if c == '"' {
		l.advance()
		var sb strings.Builder
		sb.WriteRune('"')
		for l.peek() != '"' && l.peek() != 0 && l.peek() != '\n' {
			ch := l.advance()
			sb.WriteRune(ch)
			if ch == '\\' && l.peek() != 0 {
				sb.WriteRune(l.advance())
			}
		}
		if l.peek() == '"' {
			l.advance()
		}
		sb.WriteRune('"')
		return token{tokString, sb.String(), startLine, startCol}
	}

	// @ident
	if c == '@' {
		l.advance()
		var sb strings.Builder
		sb.WriteRune('@')
		for isIdentRune(l.peek()) {
			sb.WriteRune(l.advance())
		}
		return token{tokAtIdent, sb.String(), startLine, startCol}
	}

	// :atom or :: or :
	if c == ':' {
		l.advance()
		if l.peek() == ':' {
			l.advance()
			return token{tokColonColon, "::", startLine, startCol}
		}
		if isIdentRune(l.peek()) {
			var sb strings.Builder
			sb.WriteRune(':')
			for isIdentRune(l.peek()) {
				sb.WriteRune(l.advance())
			}
			return token{tokAtom, sb.String(), startLine, startCol}
		}
		return token{tokColon, ":", startLine, startCol}
	}

	// .. or .
	if c == '.' {
		l.advance()
		if l.peek() == '.' {
			l.advance()
			return token{tokDotDot, "..", startLine, startCol}
		}
		return token{tokDot, ".", startLine, startCol}
	}

	// -> or -
	if c == '-' {
		l.advance()
		if l.peek() == '>' {
			l.advance()
			return token{tokArrow, "->", startLine, startCol}
		}
		return token{tokOp, "-", startLine, startCol}
	}

	// |>
	if c == '|' {
		l.advance()
		if l.peek() == '>' {
			l.advance()
			return token{tokPipe, "|>", startLine, startCol}
		}
		return token{tokOp, "|", startLine, startCol}
	}

	// == or =
	if c == '=' {
		l.advance()
		if l.peek() == '=' {
			l.advance()
			return token{tokOp, "==", startLine, startCol}
		}
		return token{tokEq, "=", startLine, startCol}
	}

	// != or !
	if c == '!' {
		l.advance()
		if l.peek() == '=' {
			l.advance()
			return token{tokOp, "!=", startLine, startCol}
		}
		return token{tokOp, "!", startLine, startCol}
	}

	// <= or <
	if c == '<' {
		l.advance()
		if l.peek() == '=' {
			l.advance()
			return token{tokOp, "<=", startLine, startCol}
		}
		return token{tokOp, "<", startLine, startCol}
	}

	// >= or >
	if c == '>' {
		l.advance()
		if l.peek() == '=' {
			l.advance()
			return token{tokOp, ">=", startLine, startCol}
		}
		return token{tokOp, ">", startLine, startCol}
	}

	// Single-char punctuation
	switch c {
	case ',':
		l.advance()
		return token{tokComma, ",", startLine, startCol}
	case '(':
		l.advance()
		return token{tokLParen, "(", startLine, startCol}
	case ')':
		l.advance()
		return token{tokRParen, ")", startLine, startCol}
	case '[':
		l.advance()
		return token{tokLBracket, "[", startLine, startCol}
	case ']':
		l.advance()
		return token{tokRBracket, "]", startLine, startCol}
	case '{':
		l.advance()
		return token{tokLBrace, "{", startLine, startCol}
	case '}':
		l.advance()
		return token{tokRBrace, "}", startLine, startCol}
	case '+', '*', '/', '%':
		ch := l.advance()
		return token{tokOp, string(ch), startLine, startCol}
	}

	// Number
	if c >= '0' && c <= '9' {
		var sb strings.Builder
		if c == '0' && (l.peek2() == 'x' || l.peek2() == 'X') {
			sb.WriteRune(l.advance()) // 0
			sb.WriteRune(l.advance()) // x
			for isHexDigit(l.peek()) {
				sb.WriteRune(l.advance())
			}
			return token{tokInt, sb.String(), startLine, startCol}
		}
		for l.peek() >= '0' && l.peek() <= '9' {
			sb.WriteRune(l.advance())
		}
		if l.peek() == '.' && l.peek2() != '.' {
			sb.WriteRune(l.advance())
			for l.peek() >= '0' && l.peek() <= '9' {
				sb.WriteRune(l.advance())
			}
			return token{tokFloat, sb.String(), startLine, startCol}
		}
		return token{tokInt, sb.String(), startLine, startCol}
	}

	// Identifier or keyword
	if isIdentStartRune(c) {
		var sb strings.Builder
		for isIdentRune(l.peek()) {
			sb.WriteRune(l.advance())
		}
		return token{tokIdent, sb.String(), startLine, startCol}
	}

	// Unknown — skip
	l.advance()
	return l.next()
}

func isIdentStartRune(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

func isIdentRune(c rune) bool {
	return isIdentStartRune(c) || (c >= '0' && c <= '9') || c == '?' || c == '!'
}

func isHexDigit(c rune) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// ---------------------------------------------------------------------------
// Token stream
// ---------------------------------------------------------------------------

type tokenStream struct {
	lex *lexer
	buf []token
	pos int
}

func newTokenStream(src string) *tokenStream {
	ts := &tokenStream{lex: newLexer(src)}
	// Pre-lex all tokens (fast enough for LSP)
	for {
		t := ts.lex.next()
		ts.buf = append(ts.buf, t)
		if t.kind == tokEOF {
			break
		}
	}
	return ts
}

func (ts *tokenStream) peek() token {
	// Skip newlines for most parsing
	for ts.pos < len(ts.buf) && ts.buf[ts.pos].kind == tokNewline {
		ts.pos++
	}
	if ts.pos >= len(ts.buf) {
		return token{kind: tokEOF}
	}
	return ts.buf[ts.pos]
}

func (ts *tokenStream) peekRaw() token {
	if ts.pos >= len(ts.buf) {
		return token{kind: tokEOF}
	}
	return ts.buf[ts.pos]
}

func (ts *tokenStream) consume() token {
	t := ts.peek()
	ts.pos++
	return t
}

func (ts *tokenStream) consumeRaw() token {
	if ts.pos >= len(ts.buf) {
		return token{kind: tokEOF}
	}
	t := ts.buf[ts.pos]
	ts.pos++
	return t
}

func (ts *tokenStream) expect(kind tokenKind) token {
	t := ts.consume()
	if t.kind != kind {
		// Don't panic — just return what we got
	}
	return t
}

func (ts *tokenStream) skipUntil(keywords ...string) {
	for {
		t := ts.peek()
		if t.kind == tokEOF {
			return
		}
		if t.kind == tokIdent {
			for _, kw := range keywords {
				if t.text == kw {
					return
				}
			}
		}
		ts.consume()
	}
}

func (ts *tokenStream) skipBlock() {
	// Skip until matching 'end', counting nested do/end pairs
	depth := 1
	for depth > 0 {
		t := ts.consume()
		if t.kind == tokEOF {
			return
		}
		if t.kind == tokIdent {
			switch t.text {
			case "do", "defstruct":
				depth++
			case "end":
				depth--
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

// parse parses a Chasm source file and returns all extracted symbols.
// docPath is the absolute filesystem path of the file being parsed (used for
// resolving imports). Pass "" if unknown.
func parse(src string, docPath string) *parseResult {
	pr := &parseResult{
		fns:     make(map[string]*fnInfo),
		attrs:   make(map[string]*attrInfo),
		structs: make(map[string]*structInfo),
		enums:   make(map[string]*enumInfo),
	}
	ts := newTokenStream(src)
	lines := strings.Split(src, "\n")

	for {
		t := ts.peek()
		if t.kind == tokEOF {
			break
		}

		if t.kind != tokIdent && t.kind != tokAtIdent {
			ts.consume()
			continue
		}

		switch t.text {
		case "def", "defp":
			parseFn(ts, pr, lines)
		case "defstruct":
			parseStruct(ts, pr)
		case "enum":
			parseEnum(ts, pr)
		case "import":
			parseImport(ts, pr, docPath)
		case "extern":
			parseExtern(ts, pr)
		default:
			if t.kind == tokAtIdent {
				parseAttr(ts, pr, lines)
			} else {
				ts.consume()
			}
		}
	}

	// Second pass: check for undefined function calls and unused attrs
	checkUndefined(pr, src, lines)

	return pr
}

// ---------------------------------------------------------------------------
// Parse import statement
// ---------------------------------------------------------------------------

func parseImport(ts *tokenStream, pr *parseResult, docPath string) {
	ts.consume() // skip 'import'
	pathTok := ts.consume()
	if pathTok.kind != tokString {
		return
	}
	// Strip surrounding quotes
	raw := pathTok.text
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"' {
		raw = raw[1 : len(raw)-1]
	}

	// Derive alias from basename (e.g. "std/math" → "math", "utils" → "utils")
	base := raw
	if idx := strings.LastIndex(base, "/"); idx >= 0 {
		base = base[idx+1:]
	}
	if strings.HasSuffix(base, ".chasm") {
		base = base[:len(base)-6]
	}

	imp := importInfo{
		alias: base,
		path:  raw,
	}

	// Resolve and parse the imported file
	if docPath != "" {
		symbols, resolved := resolveImportSymbols(raw, docPath)
		imp.symbols = symbols
		imp.resolvedPath = resolved
	}

	pr.imports = append(pr.imports, imp)
}

// ---------------------------------------------------------------------------
// Parse function declaration
// ---------------------------------------------------------------------------

func parseFn(ts *tokenStream, pr *parseResult, lines []string) {
	kw := ts.consume() // def or defp
	isPrivate := kw.text == "defp"

	nameTok := ts.consume()
	if nameTok.kind != tokIdent {
		return
	}
	name := nameTok.text
	defRange := tokenRange(nameTok)

	// Parse params
	var params []paramInfo
	var sigParts []string
	sigParts = append(sigParts, kw.text+" "+name)

	if ts.peek().kind == tokLParen {
		ts.consume() // (
		sigParts = append(sigParts, "(")
		first := true
		for ts.peek().kind != tokRParen && ts.peek().kind != tokEOF {
			if !first {
				ts.consume() // ,
				sigParts = append(sigParts, ", ")
			}
			first = false
			pname := ts.consume()
			if pname.kind != tokIdent {
				break
			}
			if ts.peek().kind == tokColonColon {
				ts.consume() // ::
				ptype := parseTypeExpr(ts)
				params = append(params, paramInfo{pname.text, ptype})
				sigParts = append(sigParts, pname.text+" :: "+ptype)
			} else {
				params = append(params, paramInfo{pname.text, "?"})
				sigParts = append(sigParts, pname.text)
			}
		}
		if ts.peek().kind == tokRParen {
			ts.consume()
		}
		sigParts = append(sigParts, ")")
	}

	// Return type
	retType := "void"
	if ts.peek().kind == tokColonColon {
		ts.consume()
		retType = parseTypeExpr(ts)
		sigParts = append(sigParts, " :: "+retType)
	}

	// Collect doc comment from preceding lines
	doc := extractDocComment(lines, kw.line)

	// Skip body
	bodyStart := ts.peek()
	if ts.peek().kind == tokIdent && ts.peek().text == "do" {
		ts.consume()
		ts.skipBlock()
	}
	bodyEnd := ts.peek()

	fn := &fnInfo{
		name:      name,
		sig:       strings.Join(sigParts, ""),
		doc:       doc,
		defRange:  defRange,
		bodyRange: rangeFromLines(kw.line, bodyStart.line, bodyEnd.line),
		isPrivate: isPrivate,
		params:    params,
		retType:   retType,
	}
	pr.fns[name] = fn
	pr.fnList = append(pr.fnList, fn)
}

// ---------------------------------------------------------------------------
// Parse struct declaration
// ---------------------------------------------------------------------------

func parseStruct(ts *tokenStream, pr *parseResult) {
	ts.consume() // defstruct
	nameTok := ts.consume()
	if nameTok.kind != tokIdent {
		return
	}
	name := nameTok.text
	defRange := tokenRange(nameTok)

	var fields []fieldInfo
	var declLines []string
	declLines = append(declLines, "defstruct "+name+" do")

	startLine := nameTok.line
	endLine := nameTok.line

	if ts.peek().kind == tokIdent && ts.peek().text == "do" {
		ts.consume()
		for {
			t := ts.peek()
			if t.kind == tokEOF || (t.kind == tokIdent && t.text == "end") {
				if t.kind == tokIdent {
					endLine = t.line
					ts.consume()
				}
				break
			}
			if t.kind == tokIdent {
				fname := ts.consume()
				ftype := ""
				if ts.peek().kind == tokColonColon {
					ts.consume()
					ftype = parseTypeExpr(ts)
				}
				fields = append(fields, fieldInfo{fname.text, ftype})
				declLines = append(declLines, "  "+fname.text+" :: "+ftype)
			} else {
				ts.consume()
			}
		}
	}
	declLines = append(declLines, "end")

	st := &structInfo{
		name:      name,
		decl:      strings.Join(declLines, "\n"),
		defRange:  defRange,
		bodyRange: rangeFromLines(startLine, startLine, endLine),
		fields:    fields,
	}
	pr.structs[name] = st
	pr.structList = append(pr.structList, st)
}

// ---------------------------------------------------------------------------
// Parse enum declaration
// ---------------------------------------------------------------------------

func parseEnum(ts *tokenStream, pr *parseResult) {
	ts.consume() // enum
	nameTok := ts.consume()
	if nameTok.kind != tokIdent {
		return
	}
	name := nameTok.text
	defRange := tokenRange(nameTok)

	var variants []string
	var declLines []string
	declLines = append(declLines, "enum "+name+" {")

	startLine := nameTok.line
	endLine := nameTok.line

	if ts.peek().kind == tokLBrace {
		ts.consume()
		for ts.peek().kind != tokRBrace && ts.peek().kind != tokEOF {
			t := ts.consume()
			if t.kind == tokIdent {
				v := t.text
				// Optional payload
				if ts.peek().kind == tokLParen {
					ts.consume()
					var payloadParts []string
					for ts.peek().kind != tokRParen && ts.peek().kind != tokEOF {
						pt := ts.consume()
						if pt.kind == tokIdent || pt.kind == tokLBracket || pt.kind == tokRBracket {
							payloadParts = append(payloadParts, pt.text)
						}
						if ts.peek().kind == tokComma {
							ts.consume()
							payloadParts = append(payloadParts, ", ")
						}
					}
					if ts.peek().kind == tokRParen {
						ts.consume()
					}
					v += "(" + strings.Join(payloadParts, "") + ")"
				}
				variants = append(variants, v)
				declLines = append(declLines, "  "+v+",")
				endLine = t.line
			}
			if ts.peek().kind == tokComma {
				ts.consume()
			}
		}
		if ts.peek().kind == tokRBrace {
			endLine = ts.peek().line
			ts.consume()
		}
	}
	declLines = append(declLines, "}")

	en := &enumInfo{
		name:      name,
		decl:      strings.Join(declLines, "\n"),
		defRange:  defRange,
		bodyRange: rangeFromLines(startLine, startLine, endLine),
		variants:  variants,
	}
	pr.enums[name] = en
	pr.enumList = append(pr.enumList, en)
}

// ---------------------------------------------------------------------------
// Parse extern declaration
// ---------------------------------------------------------------------------

func parseExtern(ts *tokenStream, pr *parseResult) {
	ts.consume() // extern
	if ts.peek().kind == tokIdent && ts.peek().text == "fn" {
		ts.consume() // fn
	}
	nameTok := ts.consume()
	if nameTok.kind != tokIdent {
		return
	}
	name := nameTok.text
	// Build a minimal sig
	sig := "extern fn " + name + "(...)"
	// Skip to end of line
	for ts.peekRaw().kind != tokNewline && ts.peekRaw().kind != tokEOF {
		ts.consumeRaw()
	}
	fn := &fnInfo{
		name:     name,
		sig:      sig,
		defRange: tokenRange(nameTok),
	}
	pr.fns[name] = fn
	pr.fnList = append(pr.fnList, fn)
}

// ---------------------------------------------------------------------------
// Parse module attribute declaration
// ---------------------------------------------------------------------------

func parseAttr(ts *tokenStream, pr *parseResult, lines []string) {
	atTok := ts.consume()  // @name
	name := atTok.text[1:] // strip @

	lifetime := "script"
	typ := "?"

	if ts.peek().kind == tokColonColon {
		ts.consume()
		// Could be lifetime keyword or type
		next := ts.peek()
		if next.kind == tokIdent {
			switch next.text {
			case "frame", "script", "persistent":
				lifetime = next.text
				ts.consume()
				// Optionally followed by type
				if ts.peek().kind == tokIdent || ts.peek().kind == tokLBracket {
					typ = parseTypeExpr(ts)
				}
			default:
				typ = parseTypeExpr(ts)
			}
		}
	}

	// Skip = expr
	if ts.peek().kind == tokEq {
		ts.consume()
		skipExpr(ts)
	}

	doc := extractDocComment(lines, atTok.line)
	decl := fmt.Sprintf("%s :: %s = ...", atTok.text, lifetime)
	if typ != "?" {
		decl = fmt.Sprintf("%s :: %s %s = ...", atTok.text, lifetime, typ)
	}

	at := &attrInfo{
		name:     name,
		typ:      typ,
		lifetime: lifetime,
		decl:     decl,
		doc:      doc,
		defRange: tokenRange(atTok),
	}
	pr.attrs[name] = at
	pr.attrList = append(pr.attrList, at)
}

// ---------------------------------------------------------------------------
// Parse type expression (returns string representation)
// ---------------------------------------------------------------------------

func parseTypeExpr(ts *tokenStream) string {
	t := ts.peek()
	if t.kind == tokLBracket {
		ts.consume()
		if ts.peek().kind == tokRBracket {
			ts.consume()
		}
		inner := parseTypeExpr(ts)
		return "[]" + inner
	}
	if t.kind == tokIdent {
		ts.consume()
		return t.text
	}
	return "?"
}

// ---------------------------------------------------------------------------
// Skip an expression (for attribute initializers etc.)
// ---------------------------------------------------------------------------

func skipExpr(ts *tokenStream) {
	depth := 0
	for {
		t := ts.peekRaw()
		if t.kind == tokEOF || t.kind == tokNewline {
			return
		}
		if t.kind == tokLParen || t.kind == tokLBracket || t.kind == tokLBrace {
			depth++
		}
		if t.kind == tokRParen || t.kind == tokRBracket || t.kind == tokRBrace {
			if depth == 0 {
				return
			}
			depth--
		}
		ts.consumeRaw()
	}
}

// ---------------------------------------------------------------------------
// Semantic checks
// ---------------------------------------------------------------------------

func checkUndefined(pr *parseResult, src string, lines []string) {
	// Check for unclosed do/end blocks (simple heuristic)
	doCount := 0
	endCount := 0
	ts := newTokenStream(src)
	for {
		t := ts.consume()
		if t.kind == tokEOF {
			break
		}
		if t.kind == tokIdent {
			switch t.text {
			case "do":
				doCount++
			case "end":
				endCount++
			}
		}
	}
	if doCount > endCount {
		// Find the last 'do' without a matching 'end'
		lastLine := len(lines) - 1
		pr.errors = append(pr.errors, diagEntry{
			rng: Range{
				Start: Position{lastLine, 0},
				End:   Position{lastLine, len(lines[lastLine])},
			},
			msg: fmt.Sprintf("missing %d `end` keyword(s) — unclosed block", doCount-endCount),
		})
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func tokenRange(t token) Range {
	end := t.col + len([]rune(t.text))
	return Range{
		Start: Position{t.line, t.col},
		End:   Position{t.line, end},
	}
}

func rangeFromLines(defLine, startLine, endLine int) Range {
	return Range{
		Start: Position{startLine, 0},
		End:   Position{endLine, 999},
	}
}

func extractDocComment(lines []string, declLine int) string {
	if declLine <= 0 {
		return ""
	}
	var comments []string
	for i := declLine - 1; i >= 0; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasPrefix(trimmed, "#") {
			comments = append([]string{strings.TrimSpace(trimmed[1:])}, comments...)
		} else if trimmed == "" {
			break
		} else {
			break
		}
	}
	return strings.Join(comments, "\n")
}
