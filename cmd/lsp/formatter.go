package main

import (
	"regexp"
	"strings"
	"unicode"
)

// formatDocument formats a Chasm source file following Ruby-style conventions:
//   - 2-space indentation driven by do/end block depth
//   - One blank line between top-level declarations (def, defp, defstruct, enum)
//   - Spaces around binary operators: + - * / == != < > <= >= and or
//   - Space after commas, space after colon in struct literals
//   - # comments get a space after the hash
//   - Aligned @attr declaration blocks (:: and = columns line up)
//   - Strip trailing whitespace
func formatDocument(src string) string {
	// Pass 1: normalize each line individually (operators, commas, comments)
	lines := strings.Split(src, "\n")
	var normed []string
	for _, l := range lines {
		normed = append(normed, normalizeLine(strings.TrimSpace(l)))
	}

	// Pass 2: re-indent based on do/end depth
	indented := reindent(normed)

	// Pass 3: align consecutive @attr declaration blocks
	aligned := alignAttrBlocks(indented)

	// Finalize: collapse multiple blank lines, strip trailing blanks, ensure trailing newline
	return finalize(aligned)
}

// ---- Pass 1: per-line normalization ----------------------------------------

var reAttrLine = regexp.MustCompile(`^@\w+\s*::`)

// normalizeLine applies all character-level normalizations to a single trimmed line.
func normalizeLine(line string) string {
	if line == "" {
		return ""
	}
	// Split trailing comment before normalizing code
	code, comment := splitComment(line)

	code = normalizeColonColonSpacing(code)
	code = normalizeCommas(code)
	code = normalizeStructColons(code)
	code = normalizeOperators(code)
	code = normalizeEqualSign(code)
	code = strings.TrimRight(code, " \t")

	if comment != "" {
		comment = normalizeComment(comment)
	}
	return code + comment
}

// splitComment splits a line into its code part and trailing comment (including the #).
// Handles # inside strings correctly.
func splitComment(line string) (code, comment string) {
	inStr := false
	interp := 0
	runes := []rune(line)
	for i, c := range runes {
		if inStr {
			if c == '\\' {
				continue // next rune is escaped, handled by index advance
			}
			if c == '#' && interp == 0 && i+1 < len(runes) && runes[i+1] == '{' {
				interp++
				continue
			}
			if c == '}' && interp > 0 {
				interp--
				continue
			}
			if c == '"' && interp == 0 {
				inStr = false
			}
			continue
		}
		if c == '"' {
			inStr = true
			continue
		}
		if c == '#' {
			return string(runes[:i]), string(runes[i:])
		}
	}
	return line, ""
}

// normalizeComment ensures exactly one space after # (but not #! or ##).
func normalizeComment(c string) string {
	if len(c) < 2 {
		return c
	}
	// "#!" and "##" stay as-is
	if c[1] == '!' || c[1] == '#' {
		return c
	}
	// Already has space
	if c[1] == ' ' {
		return strings.TrimRight(c, " \t")
	}
	return "# " + strings.TrimRight(c[1:], " \t")
}

// normalizeColonColonSpacing ensures exactly one space around ::.
func normalizeColonColonSpacing(line string) string {
	parts := strings.Split(line, "::")
	if len(parts) <= 1 {
		return line
	}
	for i := range parts {
		parts[i] = strings.TrimRight(parts[i], " \t")
		if i > 0 {
			parts[i] = strings.TrimLeft(parts[i], " \t")
		}
	}
	return strings.Join(parts, " :: ")
}

// normalizeCommas ensures exactly one space after each comma (not inside strings).
func normalizeCommas(line string) string {
	var sb strings.Builder
	runes := []rune(line)
	inStr := false
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		if c == '"' {
			inStr = !inStr
		}
		if !inStr && c == ',' {
			sb.WriteRune(',')
			// Skip existing spaces after comma, then write exactly one
			j := i + 1
			for j < len(runes) && runes[j] == ' ' {
				j++
			}
			if j < len(runes) && runes[j] != '\n' {
				sb.WriteRune(' ')
			}
			i = j - 1
			continue
		}
		// Remove space before comma
		if !inStr && c == ' ' && i+1 < len(runes) && runes[i+1] == ',' {
			continue
		}
		sb.WriteRune(c)
	}
	return sb.String()
}

// normalizeStructColons ensures a space after : in struct literal fields (key: value).
// e.g. {x:1.0, y:2.0} → {x: 1.0, y: 2.0}
func normalizeStructColons(line string) string {
	var sb strings.Builder
	runes := []rune(line)
	inStr := false
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		if c == '"' {
			inStr = !inStr
		}
		if !inStr && c == ':' {
			// Skip :: (already handled) and ->
			if i+1 < len(runes) && (runes[i+1] == ':' || runes[i+1] == '-' || runes[i+1] == ')') {
				sb.WriteRune(c)
				continue
			}
			// Must be preceded by a word character (struct key)
			if i > 0 && (unicode.IsLetter(runes[i-1]) || unicode.IsDigit(runes[i-1]) || runes[i-1] == '_') {
				sb.WriteRune(':')
				// Ensure space after
				if i+1 < len(runes) && runes[i+1] != ' ' {
					sb.WriteRune(' ')
				}
				continue
			}
		}
		sb.WriteRune(c)
	}
	return sb.String()
}

// normalizeOperators spaces binary operators: + - * / == != <= >= < > and or
func normalizeOperators(line string) string {
	var sb strings.Builder
	runes := []rune(line)
	n := len(runes)
	inStr := false

	for i := 0; i < n; i++ {
		c := runes[i]

		if c == '"' {
			inStr = !inStr
			sb.WriteRune(c)
			continue
		}
		if inStr {
			sb.WriteRune(c)
			continue
		}

		// Two-character operators: == != <= >= ->
		if i+1 < n {
			two := string(runes[i : i+2])
			switch two {
			case "==", "!=", "<=", ">=", "->":
				ensureSpaceInBuilder(&sb)
				sb.WriteString(two)
				ensureSpaceAfter(&sb, runes, i+2)
				i++
				continue
			}
		}

		// Single-char binary operators: + * /
		// (- handled separately for unary vs binary)
		switch c {
		case '+', '*', '/':
			// Skip * in 0x hex literals: look back for 0x
			if c == '*' {
				// unlikely but safe
			}
			ensureSpaceInBuilder(&sb)
			sb.WriteRune(c)
			ensureSpaceAfterRune(&sb, runes, i+1)
			continue

		case '-':
			// Binary minus: preceded by alnum, ), ], @, or closing quote
			if isBinaryContext(sb.String()) {
				ensureSpaceInBuilder(&sb)
				sb.WriteRune('-')
				ensureSpaceAfterRune(&sb, runes, i+1)
				continue
			}
			sb.WriteRune(c)
			continue
		}

		sb.WriteRune(c)
	}
	return sb.String()
}

// isBinaryContext returns true if the character before an operator makes it binary.
func isBinaryContext(before string) bool {
	if before == "" {
		return false
	}
	last := rune(before[len(before)-1])
	return unicode.IsLetter(last) || unicode.IsDigit(last) ||
		last == ')' || last == ']' || last == '_' || last == '"' || last == '@'
}

// ensureSpaceInBuilder adds a space to sb if the last char isn't already a space.
func ensureSpaceInBuilder(sb *strings.Builder) {
	s := sb.String()
	if len(s) > 0 && s[len(s)-1] != ' ' {
		sb.WriteRune(' ')
	}
}

// ensureSpaceAfter ensures runes[idx] is preceded by a space in sb.
func ensureSpaceAfter(sb *strings.Builder, runes []rune, idx int) {
	if idx < len(runes) && runes[idx] != ' ' && runes[idx] != '\t' {
		sb.WriteRune(' ')
	}
}

// ensureSpaceAfterRune is ensureSpaceAfter for single index.
func ensureSpaceAfterRune(sb *strings.Builder, runes []rune, idx int) {
	ensureSpaceAfter(sb, runes, idx)
}

// normalizeEqualSign ensures spaces around standalone = (not ==, !=, <=, >=, ->, =>).
func normalizeEqualSign(line string) string {
	var sb strings.Builder
	runes := []rune(line)
	inStr := false
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		if c == '"' {
			inStr = !inStr
			sb.WriteRune(c)
			continue
		}
		if inStr {
			sb.WriteRune(c)
			continue
		}
		if c == '=' {
			prev := rune(0)
			if i > 0 {
				prev = runes[i-1]
			}
			next := rune(0)
			if i+1 < len(runes) {
				next = runes[i+1]
			}
			// Skip ==, !=, <=, >=, ->, =>
			if next == '=' || prev == '!' || prev == '<' || prev == '>' || prev == '-' || prev == '=' {
				sb.WriteRune(c)
				continue
			}
			ensureSpaceInBuilder(&sb)
			sb.WriteRune('=')
			if next != 0 && next != ' ' && next != '\t' {
				sb.WriteRune(' ')
			}
			continue
		}
		sb.WriteRune(c)
	}
	return sb.String()
}

// ---- Pass 2: re-indentation ------------------------------------------------

func reindent(lines []string) []string {
	var out []string
	depth := 0
	prevWasBlank := false

	topLevel := map[string]bool{
		"def": true, "defp": true, "defstruct": true, "enum": true,
	}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if trimmed == "" {
			if !prevWasBlank {
				out = append(out, "")
			}
			prevWasBlank = true
			continue
		}
		prevWasBlank = false

		fw := firstToken(trimmed)

		// Blank line before top-level declarations
		if topLevel[fw] && len(out) > 0 && out[len(out)-1] != "" {
			out = append(out, "")
		}

		// Dedent before writing end
		if fw == "end" {
			depth--
			if depth < 0 {
				depth = 0
			}
		}
		// else: dedent, write, re-indent
		if fw == "else" && depth > 0 {
			depth--
		}

		out = append(out, strings.Repeat("  ", depth)+trimmed)

		// Indent after any line ending with " do".
		// `else do` ends with " do" AND fw == "else" — only increment once.
		if strings.HasSuffix(trimmed, " do") || trimmed == "do" {
			depth++
		} else if fw == "else" {
			depth++
		}
	}
	return out
}

// ---- Pass 3: @attr alignment -----------------------------------------------

// attrLineRe matches lines like: (indent) @name :: lifetime = value
var attrLineRe = regexp.MustCompile(`^(\s*)(@\w+)\s*::\s*(\w+)\s*=\s*(.*)$`)

// alignAttrBlocks finds consecutive @attr declaration groups and aligns :: and =.
func alignAttrBlocks(lines []string) []string {
	out := make([]string, len(lines))
	copy(out, lines)

	i := 0
	for i < len(out) {
		// Find start of a group
		if !attrLineRe.MatchString(out[i]) {
			i++
			continue
		}
		// Find end of group
		j := i
		for j < len(out) && attrLineRe.MatchString(out[j]) {
			j++
		}
		if j-i >= 2 {
			alignGroup(out, i, j)
		}
		i = j
	}
	return out
}

func alignGroup(lines []string, start, end int) {
	type parsed struct {
		indent, name, lifetime, value string
	}
	parts := make([]parsed, end-start)
	maxName, maxLifetime := 0, 0

	for i, l := range lines[start:end] {
		m := attrLineRe.FindStringSubmatch(l)
		parts[i] = parsed{m[1], m[2], m[3], m[4]}
		if len(m[2]) > maxName {
			maxName = len(m[2])
		}
		if len(m[3]) > maxLifetime {
			maxLifetime = len(m[3])
		}
	}

	for i, p := range parts {
		namePad := strings.Repeat(" ", maxName-len(p.name))
		lifePad := strings.Repeat(" ", maxLifetime-len(p.lifetime))
		lines[start+i] = p.indent + p.name + namePad + " :: " + p.lifetime + lifePad + " = " + p.value
	}
}

// ---- Finalize --------------------------------------------------------------

func finalize(lines []string) string {
	// Strip trailing blank lines
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	return strings.Join(lines, "\n") + "\n"
}

// firstToken returns the first whitespace-delimited token of a trimmed line.
func firstToken(line string) string {
	trimmed := strings.TrimSpace(line)
	idx := strings.IndexAny(trimmed, " \t(")
	if idx < 0 {
		return trimmed
	}
	return trimmed[:idx]
}
