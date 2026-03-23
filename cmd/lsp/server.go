package main

import (
	"bufio"
	"encoding/json"
	"io"
	"log"
	"sync"
)

// server holds all open documents and dispatches LSP requests.
type server struct {
	mu   sync.Mutex
	docs map[string]*document // uri → document
	w    io.Writer
}

func newServer() *server {
	return &server{docs: make(map[string]*document)}
}

func (s *server) run(r io.Reader, w io.Writer) {
	s.w = w
	br := bufio.NewReaderSize(r, 1<<20)
	for {
		raw, err := readMsg(br)
		if err != nil {
			if err != io.EOF {
				log.Printf("read: %v", err)
			}
			return
		}
		var msg rpcMsg
		if err := json.Unmarshal(raw, &msg); err != nil {
			log.Printf("unmarshal: %v", err)
			continue
		}
		go s.dispatch(msg)
	}
}

func (s *server) dispatch(msg rpcMsg) {
	switch msg.Method {
	case "initialize":
		s.handleInitialize(msg)
	case "initialized":
		// no-op
	case "shutdown":
		s.reply(msg.ID, nil)
	case "exit":
		// nothing
	case "textDocument/didOpen":
		s.handleDidOpen(msg)
	case "textDocument/didChange":
		s.handleDidChange(msg)
	case "textDocument/didClose":
		s.handleDidClose(msg)
	case "textDocument/hover":
		s.handleHover(msg)
	case "textDocument/completion":
		s.handleCompletion(msg)
	case "textDocument/definition":
		s.handleDefinition(msg)
	case "textDocument/documentSymbol":
		s.handleDocumentSymbol(msg)
	case "textDocument/formatting":
		s.handleFormatting(msg)
	case "textDocument/codeLens":
		s.handleCodeLens(msg)
	case "codeLens/resolve":
		s.handleCodeLensResolve(msg)
	default:
		if msg.ID != nil {
			s.replyErr(msg.ID, -32601, "method not found: "+msg.Method)
		}
	}
}

func (s *server) reply(id *json.RawMessage, result interface{}) {
	if id == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	writeMsg(s.w, rpcMsg{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	})
}

func (s *server) replyErr(id *json.RawMessage, code int, msg string) {
	if id == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	writeMsg(s.w, rpcMsg{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &rpcError{Code: code, Message: msg},
	})
}

func (s *server) notify(method string, params interface{}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeMsg(s.w, rpcMsg{
		JSONRPC: "2.0",
		Method:  method,
		Params:  mustMarshal(params),
	})
}

func mustMarshal(v interface{}) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------

func (s *server) handleInitialize(msg rpcMsg) {
	result := map[string]interface{}{
		"capabilities": map[string]interface{}{
			"textDocumentSync": map[string]interface{}{
				"openClose": true,
				"change":    1, // full sync
			},
			"hoverProvider":              true,
			"completionProvider":         map[string]interface{}{"triggerCharacters": []string{".", "@", ":"}},
			"definitionProvider":         true,
			"documentSymbolProvider":     true,
			"documentFormattingProvider": true,
			"codeLensProvider": map[string]interface{}{
				"resolveProvider": false,
			},
		},
		"serverInfo": map[string]string{
			"name":    "chasm-lsp",
			"version": "1.2.0",
		},
	}
	s.reply(msg.ID, result)
}

// ---------------------------------------------------------------------------
// Document sync
// ---------------------------------------------------------------------------

type didOpenParams struct {
	TextDocument struct {
		URI        string `json:"uri"`
		LanguageID string `json:"languageId"`
		Version    int    `json:"version"`
		Text       string `json:"text"`
	} `json:"textDocument"`
}

type didChangeParams struct {
	TextDocument struct {
		URI     string `json:"uri"`
		Version int    `json:"version"`
	} `json:"textDocument"`
	ContentChanges []struct {
		Text string `json:"text"`
	} `json:"contentChanges"`
}

type didCloseParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

func (s *server) handleDidOpen(msg rpcMsg) {
	var p didOpenParams
	json.Unmarshal(msg.Params, &p)
	doc := newDocument(p.TextDocument.URI, p.TextDocument.Text)
	s.mu.Lock()
	s.docs[p.TextDocument.URI] = doc
	s.mu.Unlock()
	s.publishDiagnostics(doc)
}

func (s *server) handleDidChange(msg rpcMsg) {
	var p didChangeParams
	json.Unmarshal(msg.Params, &p)
	if len(p.ContentChanges) == 0 {
		return
	}
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		doc = newDocument(p.TextDocument.URI, p.ContentChanges[0].Text)
	} else {
		doc.update(p.ContentChanges[0].Text)
	}
	s.mu.Lock()
	s.docs[p.TextDocument.URI] = doc
	s.mu.Unlock()
	s.publishDiagnostics(doc)
}

func (s *server) handleDidClose(msg rpcMsg) {
	var p didCloseParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	delete(s.docs, p.TextDocument.URI)
	s.mu.Unlock()
	// Clear diagnostics on close
	s.notify("textDocument/publishDiagnostics", map[string]interface{}{
		"uri":         p.TextDocument.URI,
		"diagnostics": []interface{}{},
	})
}

func (s *server) publishDiagnostics(doc *document) {
	diags := doc.diagnostics()
	s.notify("textDocument/publishDiagnostics", map[string]interface{}{
		"uri":         doc.uri,
		"diagnostics": diags,
	})
}

// ---------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------

type hoverParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Position Position `json:"position"`
}

func (s *server) handleHover(msg rpcMsg) {
	var p hoverParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		s.reply(msg.ID, nil)
		return
	}
	hover := doc.hover(p.Position)
	s.reply(msg.ID, hover)
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

type completionParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Position Position `json:"position"`
}

func (s *server) handleCompletion(msg rpcMsg) {
	var p completionParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		s.reply(msg.ID, []CompletionItem{})
		return
	}
	items := doc.complete(p.Position)
	s.reply(msg.ID, items)
}

// ---------------------------------------------------------------------------
// Definition
// ---------------------------------------------------------------------------

type definitionParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Position Position `json:"position"`
}

func (s *server) handleDefinition(msg rpcMsg) {
	var p definitionParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		s.reply(msg.ID, nil)
		return
	}
	loc := doc.definition(p.Position)
	s.reply(msg.ID, loc)
}

// ---------------------------------------------------------------------------
// Document symbols
// ---------------------------------------------------------------------------

type documentSymbolParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

type DocumentSymbol struct {
	Name           string           `json:"name"`
	Kind           int              `json:"kind"`
	Range          Range            `json:"range"`
	SelectionRange Range            `json:"selectionRange"`
	Children       []DocumentSymbol `json:"children,omitempty"`
}

func (s *server) handleDocumentSymbol(msg rpcMsg) {
	var p documentSymbolParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		s.reply(msg.ID, []DocumentSymbol{})
		return
	}
	s.reply(msg.ID, doc.symbols())
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

type formattingParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Options struct {
		TabSize      int  `json:"tabSize"`
		InsertSpaces bool `json:"insertSpaces"`
	} `json:"options"`
}

func (s *server) handleFormatting(msg rpcMsg) {
	var p formattingParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		s.reply(msg.ID, []TextEdit{})
		return
	}
	formatted := formatDocument(doc.text)
	if formatted == doc.text {
		s.reply(msg.ID, []TextEdit{})
		return
	}
	// Replace entire document
	lineCount := len(doc.lines)
	lastLine := ""
	if lineCount > 0 {
		lastLine = doc.lines[lineCount-1]
	}
	edit := TextEdit{
		Range: Range{
			Start: Position{0, 0},
			End:   Position{lineCount, len(lastLine)},
		},
		NewText: formatted,
	}
	s.reply(msg.ID, []TextEdit{edit})
}

// ---------------------------------------------------------------------------
// CodeLens
// ---------------------------------------------------------------------------

type codeLensParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

type CodeLens struct {
	Range   Range       `json:"range"`
	Command *LSPCommand `json:"command,omitempty"`
	Data    interface{} `json:"data,omitempty"`
}

type LSPCommand struct {
	Title     string        `json:"title"`
	Command   string        `json:"command"`
	Arguments []interface{} `json:"arguments,omitempty"`
}

func (s *server) handleCodeLens(msg rpcMsg) {
	var p codeLensParams
	json.Unmarshal(msg.Params, &p)
	s.mu.Lock()
	doc := s.docs[p.TextDocument.URI]
	s.mu.Unlock()
	if doc == nil {
		s.reply(msg.ID, []CodeLens{})
		return
	}
	s.reply(msg.ID, doc.codeLens())
}

func (s *server) handleCodeLensResolve(msg rpcMsg) {
	// We pre-populate commands in codeLens, so resolve is a pass-through.
	var lens CodeLens
	json.Unmarshal(msg.Params, &lens)
	s.reply(msg.ID, lens)
}
