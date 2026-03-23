// cmd/lsp — Chasm Language Server Protocol implementation.
//
// Speaks LSP 3.17 over stdin/stdout (JSON-RPC 2.0).
// Features: diagnostics, hover, completion, go-to-definition.
// No external LSP library — raw JSON-RPC for zero dependencies.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetPrefix("[chasm-lsp] ")
	srv := newServer()
	srv.run(os.Stdin, os.Stdout)
}

// ---------------------------------------------------------------------------
// JSON-RPC transport
// ---------------------------------------------------------------------------

type rpcMsg struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"`
	Method  string           `json:"method,omitempty"`
	Params  json.RawMessage  `json:"params,omitempty"`
	Result  interface{}      `json:"result,omitempty"`
	Error   *rpcError        `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func readMsg(r *bufio.Reader) ([]byte, error) {
	contentLen := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if strings.HasPrefix(line, "Content-Length: ") {
			n, _ := strconv.Atoi(strings.TrimPrefix(line, "Content-Length: "))
			contentLen = n
		}
	}
	if contentLen < 0 {
		return nil, fmt.Errorf("missing Content-Length")
	}
	buf := make([]byte, contentLen)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func writeMsg(w io.Writer, v interface{}) {
	body, _ := json.Marshal(v)
	fmt.Fprintf(w, "Content-Length: %d\r\n\r\n", len(body))
	w.Write(body)
}

// ---------------------------------------------------------------------------
// LSP types (minimal subset)
// ---------------------------------------------------------------------------

type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

type Location struct {
	URI   string `json:"uri"`
	Range Range  `json:"range"`
}

type Diagnostic struct {
	Range    Range  `json:"range"`
	Severity int    `json:"severity"` // 1=error 2=warn 3=info 4=hint
	Source   string `json:"source"`
	Message  string `json:"message"`
}

type TextEdit struct {
	Range   Range  `json:"range"`
	NewText string `json:"newText"`
}

type CompletionItem struct {
	Label            string `json:"label"`
	Kind             int    `json:"kind"`
	Detail           string `json:"detail,omitempty"`
	Documentation    string `json:"documentation,omitempty"`
	InsertText       string `json:"insertText,omitempty"`
	InsertTextFormat int    `json:"insertTextFormat,omitempty"` // 1=plain 2=snippet
}

type MarkupContent struct {
	Kind  string `json:"kind"` // "markdown" | "plaintext"
	Value string `json:"value"`
}

type Hover struct {
	Contents MarkupContent `json:"contents"`
	Range    *Range        `json:"range,omitempty"`
}

// Completion item kinds
const (
	CIKText        = 1
	CIKMethod      = 2
	CIKFunction    = 3
	CIKConstructor = 4
	CIKField       = 5
	CIKVariable    = 6
	CIKClass       = 7
	CIKInterface   = 8
	CIKModule      = 9
	CIKProperty    = 10
	CIKKeyword     = 14
	CIKSnippet     = 15
	CIKColor       = 16
	CIKFile        = 17
	CIKEnum        = 13
	CIKEnumMember  = 20
	CIKStruct      = 22
)
