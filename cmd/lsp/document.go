package main

import (
	"os"
	"path/filepath"
	"strings"
	"unicode"
)

// document holds the text and parsed state for one open file.
type document struct {
	uri    string
	text   string
	lines  []string
	parsed *parseResult
}

func newDocument(uri, text string) *document {
	d := &document{uri: uri}
	d.update(text)
	return d
}

func (d *document) update(text string) {
	d.text = text
	d.lines = strings.Split(text, "\n")
	d.parsed = parse(text, d.uriToPath())
}

// uriToPath converts a file:// URI to a filesystem path.
func (d *document) uriToPath() string {
	p := d.uri
	if strings.HasPrefix(p, "file://") {
		p = p[7:]
	}
	return p
}

// wordAt returns the identifier word at the given position.
func (d *document) wordAt(pos Position) (string, Range) {
	if pos.Line >= len(d.lines) {
		return "", Range{}
	}
	line := d.lines[pos.Line]
	col := pos.Character
	if col > len(line) {
		col = len(line)
	}
	// Expand left
	start := col
	for start > 0 && isIdentChar(rune(line[start-1])) {
		start--
	}
	// Include leading @ for module attrs
	if start > 0 && line[start-1] == '@' {
		start--
	}
	// Expand right
	end := col
	for end < len(line) && isIdentChar(rune(line[end])) {
		end++
	}
	if start >= end {
		return "", Range{}
	}
	word := line[start:end]
	r := Range{
		Start: Position{Line: pos.Line, Character: start},
		End:   Position{Line: pos.Line, Character: end},
	}
	return word, r
}

func isIdentChar(c rune) bool {
	return unicode.IsLetter(c) || unicode.IsDigit(c) || c == '_' || c == '?' || c == '!'
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

func (d *document) diagnostics() []Diagnostic {
	if d.parsed == nil {
		return nil
	}
	var out []Diagnostic
	for _, e := range d.parsed.errors {
		out = append(out, Diagnostic{
			Range:    e.rng,
			Severity: 1,
			Source:   "chasm",
			Message:  e.msg,
		})
	}
	for _, w := range d.parsed.warnings {
		out = append(out, Diagnostic{
			Range:    w.rng,
			Severity: 2,
			Source:   "chasm",
			Message:  w.msg,
		})
	}
	return out
}

// ---------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------

func (d *document) hover(pos Position) *Hover {
	if d.parsed == nil {
		return nil
	}
	word, rng := d.wordAt(pos)
	if word == "" {
		return nil
	}

	// Module attribute
	if strings.HasPrefix(word, "@") {
		name := word[1:]
		if attr, ok := d.parsed.attrs[name]; ok {
			md := "```chasm\n" + attr.decl + "\n```\n\n" + attr.doc
			return &Hover{Contents: MarkupContent{Kind: "markdown", Value: md}, Range: &rng}
		}
	}

	// Function
	if fn, ok := d.parsed.fns[word]; ok {
		md := "```chasm\n" + fn.sig + "\n```"
		if fn.doc != "" {
			md += "\n\n" + fn.doc
		}
		return &Hover{Contents: MarkupContent{Kind: "markdown", Value: md}, Range: &rng}
	}

	// Struct
	if st, ok := d.parsed.structs[word]; ok {
		md := "```chasm\n" + st.decl + "\n```"
		return &Hover{Contents: MarkupContent{Kind: "markdown", Value: md}, Range: &rng}
	}

	// Enum
	if en, ok := d.parsed.enums[word]; ok {
		md := "```chasm\n" + en.decl + "\n```"
		return &Hover{Contents: MarkupContent{Kind: "markdown", Value: md}, Range: &rng}
	}

	// Keyword / builtin
	if doc, ok := builtinDocs[word]; ok {
		return &Hover{Contents: MarkupContent{Kind: "markdown", Value: doc}, Range: &rng}
	}

	return nil
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

// complete returns completion items for the given cursor position.
// Handles: dot-trigger (methods + import symbols), @-trigger, :-trigger,
// and general keyword/builtin/user-symbol completions.
func (d *document) complete(pos Position) []CompletionItem {
	var items []CompletionItem

	if pos.Line >= len(d.lines) {
		return keywordItems()
	}
	line := d.lines[pos.Line]
	col := pos.Character
	if col > len(line) {
		col = len(line)
	}
	prefix := line[:col]

	// After '.' or 'alias.partial' — dot-based member access.
	// Handles both the exact trigger (ends with '.') and continued typing after dot.
	if alias, ok := dotContextAlias(prefix); ok {
		if alias != "" && d.parsed != nil {
			for _, imp := range d.parsed.imports {
				if imp.alias == alias {
					if imp.symbols != nil {
						for name, fn := range imp.symbols.fns {
							if !fn.isPrivate {
								items = append(items, CompletionItem{
									Label:            name,
									Kind:             CIKFunction,
									Detail:           fn.sig,
									InsertText:       name + "($0)",
									InsertTextFormat: 2,
								})
							}
						}
					}
					return items
				}
			}
		}
		// Generic method completions
		items = append(items, methodItems()...)
		return items
	}

	// After '@' — module attr completions
	if strings.HasSuffix(prefix, "@") || atTrigger(prefix) {
		if d.parsed != nil {
			for name, attr := range d.parsed.attrs {
				items = append(items, CompletionItem{
					Label:  "@" + name,
					Kind:   CIKVariable,
					Detail: attr.typ,
				})
			}
		}
		return items
	}

	// After ':' — atom completions
	if strings.HasSuffix(prefix, ":") {
		items = append(items, atomItems()...)
		return items
	}

	// General: keywords + builtins + user symbols
	items = append(items, keywordItems()...)
	items = append(items, builtinItems()...)

	if d.parsed != nil {
		for name, fn := range d.parsed.fns {
			items = append(items, CompletionItem{
				Label:            name,
				Kind:             CIKFunction,
				Detail:           fn.sig,
				InsertText:       name + "($0)",
				InsertTextFormat: 2,
			})
		}
		for name, attr := range d.parsed.attrs {
			items = append(items, CompletionItem{
				Label:  "@" + name,
				Kind:   CIKVariable,
				Detail: attr.typ,
			})
		}
		for name := range d.parsed.structs {
			items = append(items, CompletionItem{Label: name, Kind: CIKStruct})
		}
		for name := range d.parsed.enums {
			items = append(items, CompletionItem{Label: name, Kind: CIKEnum})
		}
		// Import module names as completion items
		for _, imp := range d.parsed.imports {
			items = append(items, CompletionItem{
				Label:  imp.alias,
				Kind:   CIKModule,
				Detail: "import \"" + imp.path + "\"",
			})
		}
	}

	return items
}

// dotAlias extracts the identifier immediately before a trailing dot.
// e.g. "  utils." → "utils", "foo.bar." → "bar"
func dotAlias(prefix string) string {
	trimmed := strings.TrimRight(prefix, " \t")
	if len(trimmed) == 0 || trimmed[len(trimmed)-1] != '.' {
		return ""
	}
	trimmed = trimmed[:len(trimmed)-1] // remove the dot
	// Walk back to find the identifier
	end := len(trimmed)
	start := end
	for start > 0 && isIdentChar(rune(trimmed[start-1])) {
		start--
	}
	return trimmed[start:end]
}

func dotTrigger(prefix string) bool {
	trimmed := strings.TrimRight(prefix, " \t")
	return len(trimmed) > 0 && trimmed[len(trimmed)-1] == '.'
}

// dotContextAlias returns the identifier before the dot when the prefix is in a
// dot-completion context — either ending with '.' (e.g. "@enemies.") or with
// 'alias.partial' (e.g. "@enemies.se" typed after the initial trigger).
// Returns ("", false) when no dot context is detected.
func dotContextAlias(prefix string) (string, bool) {
	trimmed := strings.TrimRight(prefix, " \t")
	if len(trimmed) == 0 {
		return "", false
	}
	// Strip trailing ident chars (partial method name typed after dot)
	end := len(trimmed)
	for end > 0 && isIdentChar(rune(trimmed[end-1])) {
		end--
	}
	// Must have a '.' immediately before what we stripped
	if end == 0 || trimmed[end-1] != '.' {
		return "", false
	}
	return dotAlias(trimmed[:end]), true
}

func atTrigger(prefix string) bool {
	trimmed := strings.TrimRight(prefix, " \t")
	return len(trimmed) > 0 && trimmed[len(trimmed)-1] == '@'
}

// ---------------------------------------------------------------------------
// Definition
// ---------------------------------------------------------------------------

func (d *document) definition(pos Position) *Location {
	if d.parsed == nil {
		return nil
	}
	word, _ := d.wordAt(pos)
	if word == "" {
		return nil
	}
	name := word
	if strings.HasPrefix(word, "@") {
		name = word[1:]
		if attr, ok := d.parsed.attrs[name]; ok {
			return &Location{URI: d.uri, Range: attr.defRange}
		}
		return nil
	}
	if fn, ok := d.parsed.fns[name]; ok {
		return &Location{URI: d.uri, Range: fn.defRange}
	}
	if st, ok := d.parsed.structs[name]; ok {
		return &Location{URI: d.uri, Range: st.defRange}
	}
	if en, ok := d.parsed.enums[name]; ok {
		return &Location{URI: d.uri, Range: en.defRange}
	}
	// Check imported symbols — jump to the source file
	if d.parsed != nil {
		for _, imp := range d.parsed.imports {
			if imp.symbols != nil {
				if fn, ok := imp.symbols.fns[name]; ok {
					impURI := pathToURI(imp.resolvedPath)
					return &Location{URI: impURI, Range: fn.defRange}
				}
			}
		}
	}
	return nil
}

func pathToURI(p string) string {
	if strings.HasPrefix(p, "/") {
		return "file://" + p
	}
	return "file:///" + p
}

// ---------------------------------------------------------------------------
// Document symbols
// ---------------------------------------------------------------------------

func (d *document) symbols() []DocumentSymbol {
	if d.parsed == nil {
		return nil
	}
	var out []DocumentSymbol
	for _, fn := range d.parsed.fnList {
		out = append(out, DocumentSymbol{
			Name:           fn.name,
			Kind:           12, // Function
			Range:          fn.bodyRange,
			SelectionRange: fn.defRange,
		})
	}
	for _, st := range d.parsed.structList {
		out = append(out, DocumentSymbol{
			Name:           st.name,
			Kind:           23, // Struct
			Range:          st.bodyRange,
			SelectionRange: st.defRange,
		})
	}
	for _, en := range d.parsed.enumList {
		out = append(out, DocumentSymbol{
			Name:           en.name,
			Kind:           10, // Enum
			Range:          en.bodyRange,
			SelectionRange: en.defRange,
		})
	}
	for _, at := range d.parsed.attrList {
		out = append(out, DocumentSymbol{
			Name:           "@" + at.name,
			Kind:           CIKVariable,
			Range:          at.defRange,
			SelectionRange: at.defRange,
		})
	}
	return out
}

// ---------------------------------------------------------------------------
// CodeLens
// ---------------------------------------------------------------------------

// codeLens returns ▶ Run lenses above on_tick, on_init, on_draw, and main.
func (d *document) codeLens() []CodeLens {
	if d.parsed == nil {
		return nil
	}
	runTargets := map[string]bool{
		"on_tick": true, "on_init": true, "on_draw": true, "main": true,
	}
	var lenses []CodeLens
	for _, fn := range d.parsed.fnList {
		if runTargets[fn.name] {
			lenses = append(lenses, CodeLens{
				Range: fn.defRange,
				Command: &LSPCommand{
					Title:     "▶ Run",
					Command:   "chasm.runFile",
					Arguments: []interface{}{d.uriToPath()},
				},
			})
		}
	}
	return lenses
}

// ---------------------------------------------------------------------------
// Import symbol resolution
// ---------------------------------------------------------------------------

// resolveImportSymbols parses an imported file and returns its parseResult.
// importPath is the raw string from the import statement (e.g. "std/math").
// docPath is the absolute path of the importing document.
func resolveImportSymbols(importPath, docPath string) (*parseResult, string) {
	if !strings.HasSuffix(importPath, ".chasm") {
		importPath += ".chasm"
	}
	dir := filepath.Dir(docPath)

	// Search order: relative to doc, then $CHASM_HOME/std/
	candidates := []string{
		filepath.Join(dir, importPath),
	}
	if home := chasmHomeForLSP(); home != "" {
		candidates = append(candidates,
			filepath.Join(home, "std", importPath),
			filepath.Join(home, importPath),
		)
	}

	for _, candidate := range candidates {
		data, err := os.ReadFile(candidate)
		if err == nil {
			pr := parse(string(data), candidate)
			return pr, candidate
		}
	}
	return nil, ""
}

// chasmHomeForLSP returns the Chasm repo root for the LSP process.
// Checks $CHASM_HOME env var only (no fatal exit).
func chasmHomeForLSP() string {
	return os.Getenv("CHASM_HOME")
}
