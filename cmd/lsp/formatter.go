package main

import (
	"strings"
)

// formatDocument applies Chasm formatting rules to source text:
//   - 2-space indentation (tabs → spaces, re-indent based on block depth)
//   - One blank line between top-level declarations
//   - Consistent spacing around `::` and `=`
//   - Strip trailing whitespace
func formatDocument(src string) string {
	lines := strings.Split(src, "\n")
	var out []string

	depth := 0
	prevWasBlank := false
	prevWasTopLevel := false

	// Top-level keywords that start a block
	topLevelStarters := map[string]bool{
		"def": true, "defp": true, "defstruct": true, "enum": true,
	}
	// Keywords that increase indent depth
	blockOpeners := map[string]bool{
		"do": true, "defstruct": true,
	}
	// Keywords that decrease indent depth
	blockClosers := map[string]bool{
		"end": true,
	}
	// Keywords that both decrease and increase (else, when handled inline)
	blockMiddle := map[string]bool{
		"else": true,
	}

	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)

		// Blank line handling
		if trimmed == "" {
			if !prevWasBlank {
				out = append(out, "")
			}
			prevWasBlank = true
			continue
		}
		prevWasBlank = false

		// Determine first token
		firstWord := firstToken(trimmed)

		// Insert blank line before top-level declarations (not the very first)
		if topLevelStarters[firstWord] && len(out) > 0 && prevWasTopLevel {
			// already have blank line or not — ensure exactly one
			if len(out) > 0 && out[len(out)-1] != "" {
				out = append(out, "")
			}
		}

		// Adjust depth before writing for closers
		if blockClosers[firstWord] {
			depth--
			if depth < 0 {
				depth = 0
			}
		}
		if blockMiddle[firstWord] && depth > 0 {
			depth--
		}

		// Build indented line
		indent := strings.Repeat("  ", depth)
		formatted := indent + normalizeSpacing(trimmed)
		out = append(out, formatted)

		// Adjust depth after writing for openers
		if blockOpeners[firstWord] {
			depth++
		}
		// enum uses { } not do/end
		if firstWord == "enum" {
			// don't change depth — enum body is on one line typically
		}
		if blockMiddle[firstWord] {
			depth++
		}

		prevWasTopLevel = topLevelStarters[firstWord]
	}

	// Remove trailing blank lines
	for len(out) > 0 && out[len(out)-1] == "" {
		out = out[:len(out)-1]
	}

	return strings.Join(out, "\n") + "\n"
}

// normalizeSpacing fixes spacing around :: and = operators.
func normalizeSpacing(line string) string {
	// Normalize :: spacing: collapse multiple spaces around ::
	line = normalizeOp(line, "::", " :: ")
	// Normalize = spacing (but not ==, !=, <=, >=, ->)
	line = normalizeEq(line)
	// Strip trailing whitespace
	line = strings.TrimRight(line, " \t")
	return line
}

// normalizeOp ensures `op` is surrounded by exactly one space on each side.
func normalizeOp(line, op, replacement string) string {
	// Simple approach: split on op, trim each part, rejoin
	parts := strings.Split(line, op)
	if len(parts) <= 1 {
		return line
	}
	for i := range parts {
		parts[i] = strings.TrimRight(parts[i], " \t")
		if i > 0 {
			parts[i] = strings.TrimLeft(parts[i], " \t")
		}
	}
	return strings.Join(parts, replacement)
}

// normalizeEq normalizes standalone `=` (not ==, !=, <=, >=, ->, =>).
func normalizeEq(line string) string {
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
			// Ensure space before =
			s := sb.String()
			if len(s) > 0 && s[len(s)-1] != ' ' {
				sb.WriteRune(' ')
			}
			sb.WriteRune('=')
			// Ensure space after =
			if next != 0 && next != ' ' && next != '\t' {
				sb.WriteRune(' ')
			}
			continue
		}
		sb.WriteRune(c)
	}
	return sb.String()
}

// firstToken returns the first whitespace-delimited token of a line.
func firstToken(line string) string {
	trimmed := strings.TrimSpace(line)
	idx := strings.IndexAny(trimmed, " \t(")
	if idx < 0 {
		return trimmed
	}
	return trimmed[:idx]
}
