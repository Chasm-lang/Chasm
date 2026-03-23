import * as path from "path";
import * as fs from "fs";
import { workspace, ExtensionContext, window, commands, Uri } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("chasm");
  let serverPath: string = config.get("serverPath") || "";

  if (!serverPath) {
    const candidates = [
      path.join(context.extensionPath, "..", "..", "bin", "chasm-lsp"),
      path.join(process.env.HOME || "", ".local", "bin", "chasm-lsp"),
      "/usr/local/bin/chasm-lsp",
    ];
    for (const c of candidates) {
      if (fs.existsSync(c)) {
        serverPath = c;
        break;
      }
    }
  }

  if (!serverPath || !fs.existsSync(serverPath)) {
    window.showWarningMessage(
      "chasm-lsp not found. Install Chasm or set chasm.serverPath in settings."
    );
    return;
  }

  const serverOptions: ServerOptions = {
    command: serverPath,
    transport: TransportKind.stdio,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "chasm" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.chasm"),
    },
  };

  client = new LanguageClient(
    "chasm-lsp",
    "Chasm Language Server",
    serverOptions,
    clientOptions
  );

  client.start();

  // ── chasm.runFile command ──────────────────────────────────────────────────
  // Triggered by CodeLens "▶ Run" or the title bar play button.
  context.subscriptions.push(
    commands.registerCommand("chasm.runFile", (filePath?: string) => {
      // filePath comes from CodeLens arguments; fall back to active editor.
      const target =
        filePath ||
        (window.activeTextEditor
          ? window.activeTextEditor.document.uri.fsPath
          : undefined);

      if (!target) {
        window.showErrorMessage("No Chasm file to run.");
        return;
      }

      const chasmBin: string = config.get("chasmPath") || "chasm";
      const terminal = window.createTerminal("Chasm Run");
      terminal.show(true);
      terminal.sendText(`${chasmBin} run "${target}"`);
    })
  );

  // ── chasm.formatFile command ───────────────────────────────────────────────
  context.subscriptions.push(
    commands.registerCommand("chasm.formatFile", () => {
      const editor = window.activeTextEditor;
      if (!editor || editor.document.languageId !== "chasm") {
        return;
      }
      commands.executeCommand("editor.action.formatDocument");
    })
  );
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) return undefined;
  return client.stop();
}
