const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

/**
 * Normalizes user input into PascalCase, camelCase, and snake_case.
 * @param {string} input
 */
function parseStoreName(input) {
  let clean = input.trim();
  // Remove trailing "Store" or "_store" or "-store" (case-insensitive)
  clean = clean.replace(/(?:_|-|\s)?store$/i, '');
  if (!clean) clean = 'Custom';

  // Convert to words split by space, underscore, hyphen, or camelCase transitions
  const words = clean
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[-_]+/g, ' ')
    .split(/\s+/)
    .filter(Boolean);

  const pascalWords = words.map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
  const basePascal = pascalWords.join('');
  const pascalName = `${basePascal}Store`;
  const camelRef = basePascal.charAt(0).toLowerCase() + basePascal.slice(1) + 'Store';
  const fileName = words.map(w => w.toLowerCase()).join('_') + '_store.dart';

  return { pascalName, camelRef, fileName };
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
  // Command: Create OrbitStore
  let disposable = vscode.commands.registerCommand('orbit.createStore', async (uri) => {
    // 1. Get Store Name from User
    const inputName = await vscode.window.showInputBox({
      prompt: 'Enter OrbitStore name (e.g. User, Cart, UserProfile)',
      placeHolder: 'User',
      validateInput: (value) => {
        if (!value || value.trim().length === 0) {
          return 'Store name cannot be empty';
        }
        if (!/^[a-zA-Z0-9_\-\s]+$/.test(value.trim())) {
          return 'Store name can only contain letters, numbers, spaces, underscores, and hyphens';
        }
        return null;
      }
    });

    if (!inputName) return;

    const { pascalName, camelRef, fileName } = parseStoreName(inputName);

    // 2. Determine Directory Target
    let targetDir;
    if (uri && uri.fsPath) {
      const stats = fs.statSync(uri.fsPath);
      targetDir = stats.isDirectory() ? uri.fsPath : path.dirname(uri.fsPath);
    } else if (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
      targetDir = path.join(vscode.workspace.workspaceFolders[0].uri.fsPath, 'lib');
      if (!fs.existsSync(targetDir)) {
        targetDir = vscode.workspace.workspaceFolders[0].uri.fsPath;
      }
    } else {
      vscode.window.showErrorMessage('No active folder or workspace found.');
      return;
    }

    const filePath = path.join(targetDir, fileName);

    if (fs.existsSync(filePath)) {
      vscode.window.showErrorMessage(`File ${fileName} already exists at destination.`);
      return;
    }

    // 3. Generate OrbitStore Template Code
    const storeTemplate = `import 'package:orbit_state/orbit.dart';

class ${pascalName} extends OrbitStore {
  int _counter = 0;
  int get counter => _counter;

  void increment() {
    mutate(() => _counter++);
  }

  @override
  Map<String, Object?> debugSnapshot() => {'counter': _counter};
}

final ${camelRef} = defineStore(() => ${pascalName}());
`;

    fs.writeFileSync(filePath, storeTemplate, 'utf8');

    const openDoc = await vscode.workspace.openTextDocument(filePath);
    await vscode.window.showTextDocument(openDoc);
    vscode.window.showInformationMessage(`Created ${fileName} successfully!`);
  });

  context.subscriptions.push(disposable);

  // Webview View Provider: Orbit State Inspector
  const provider = new OrbitStateWebviewProvider(context.extensionUri);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('orbit.stateInspector', provider)
  );

  // Listen to active debug sessions and receive debuggerUris custom event
  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((e) => {
      if (e.event === 'dart.debuggerUris') {
        const vmServiceUri = e.body.vmServiceUri;
        provider.setVmServiceUri(vmServiceUri);
      }
    })
  );

  // Also when debug session terminates, reset state
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession(() => {
      provider.clearVmServiceUri();
    })
  );
}

function deactivate() {}

class OrbitStateWebviewProvider {
  constructor(extensionUri) {
    this._extensionUri = extensionUri;
    this._view = undefined;
    this._vmServiceUri = undefined;
  }

  resolveWebviewView(webviewView, context, token) {
    this._view = webviewView;

    webviewView.webview.options = {
      enableScripts: true,
      localResourceRoots: [this._extensionUri]
    };

    webviewView.webview.html = this._getHtmlForWebview(webviewView.webview);

    webviewView.webview.onDidReceiveMessage(message => {
      if (message.command === 'ready') {
        if (this._vmServiceUri) {
          this._sendVmServiceUri();
        }
      }
    });
  }

  setVmServiceUri(uri) {
    this._vmServiceUri = uri;
    this._sendVmServiceUri();
  }

  clearVmServiceUri() {
    this._vmServiceUri = undefined;
    if (this._view) {
      this._view.webview.postMessage({ command: 'disconnect' });
    }
  }

  _sendVmServiceUri() {
    if (this._view && this._vmServiceUri) {
      this._view.webview.postMessage({
        command: 'connect',
        uri: this._vmServiceUri
      });
    }
  }

  _getHtmlForWebview(webview) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600&display=swap" rel="stylesheet">
  <style>
    body {
      font-family: 'Outfit', sans-serif;
      margin: 0;
      padding: 16px;
      color: var(--vscode-foreground, #cccccc);
      background-color: var(--vscode-sideBar-background, #1e1e1e);
      font-size: 13px;
    }
    
    .header {
      display: flex;
      align-items: center;
      margin-bottom: 16px;
      gap: 8px;
    }
    
    .indicator {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background-color: #888;
    }
    
    .indicator.connected { background-color: #4caf50; box-shadow: 0 0 8px #4caf50; }
    .indicator.connecting { background-color: #ffeb3b; box-shadow: 0 0 8px #ffeb3b; }
    .indicator.disconnected { background-color: #f44336; }
    .indicator.error { background-color: #f44336; }
    
    .status-container {
      display: flex;
      align-items: center;
      gap: 6px;
      font-weight: 600;
    }
    
    .connection-panel {
      background: rgba(255, 255, 255, 0.03);
      border: 1px solid rgba(255, 255, 255, 0.05);
      border-radius: 8px;
      padding: 12px;
      margin-bottom: 16px;
    }
    
    .input-group {
      display: flex;
      gap: 6px;
      margin-top: 8px;
    }
    
    input[type="text"] {
      flex: 1;
      background: rgba(0, 0, 0, 0.2);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 4px;
      color: #fff;
      padding: 6px 10px;
      font-size: 12px;
      font-family: inherit;
    }
    
    input:focus {
      outline: 1px solid var(--vscode-focusBorder, #007fd4);
      border-color: transparent;
    }
    
    button {
      background: var(--vscode-button-background, #007fd4);
      color: var(--vscode-button-foreground, #ffffff);
      border: none;
      padding: 6px 12px;
      border-radius: 4px;
      cursor: pointer;
      font-family: inherit;
      font-weight: 600;
      transition: background 0.2s;
    }
    
    button:hover {
      background: var(--vscode-button-hoverBackground, #0062a3);
    }
    
    .store-card {
      background: rgba(255, 255, 255, 0.02);
      border: 1px solid rgba(255, 255, 255, 0.05);
      border-radius: 8px;
      margin-bottom: 12px;
      overflow: hidden;
      transition: transform 0.2s, box-shadow 0.2s;
    }
    
    .store-card:hover {
      transform: translateY(-2px);
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
      border-color: rgba(255, 255, 255, 0.1);
    }
    
    .store-header {
      padding: 12px;
      background: rgba(255, 255, 255, 0.03);
      display: flex;
      justify-content: space-between;
      align-items: center;
      border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    }
    
    .store-name {
      font-weight: 600;
      color: var(--vscode-textLink-foreground, #3794ff);
    }
    
    .badges {
      display: flex;
      gap: 6px;
    }
    
    .badge {
      font-size: 10px;
      padding: 2px 6px;
      border-radius: 10px;
      background: rgba(255, 255, 255, 0.08);
      font-weight: 600;
    }
    
    .badge.ready {
      background: rgba(76, 175, 80, 0.15);
      color: #81c784;
    }
    
    .store-body {
      padding: 12px;
    }
    
    .state-tree {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    
    .state-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      border-bottom: 1px solid rgba(255, 255, 255, 0.02);
      padding-bottom: 4px;
    }
    
    .state-key {
      color: #9cdcfe;
      font-family: 'Courier New', Courier, monospace;
      font-weight: 600;
    }
    
    .state-val-string {
      color: #ce9178;
      font-family: 'Courier New', Courier, monospace;
    }
    
    .state-val-num {
      color: #b5cea8;
      font-family: 'Courier New', Courier, monospace;
    }
    
    .state-val-bool {
      color: #569cd6;
      font-family: 'Courier New', Courier, monospace;
    }
    
    .no-stores {
      text-align: center;
      color: #777;
      padding: 24px;
    }
    
    .refresh-container {
      display: flex;
      justify-content: flex-end;
      margin-bottom: 8px;
    }
    
    .icon-btn {
      background: transparent;
      padding: 4px;
      border: none;
      border-radius: 4px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      color: var(--vscode-foreground, #cccccc);
    }
    
    .icon-btn:hover {
      background: rgba(255, 255, 255, 0.05);
    }
  </style>
</head>
<body>
  <div class="header">
    <div class="status-container">
      <div id="status-indicator" class="indicator disconnected"></div>
      <span id="status-text">Disconnected</span>
    </div>
  </div>

  <div class="connection-panel">
    <div>Dart VM Service URL:</div>
    <div class="input-group">
      <input type="text" id="manual-uri" placeholder="ws://127.0.0.1:8181/..." />
      <button id="connect-btn">Connect</button>
    </div>
  </div>

  <div class="refresh-container">
    <button id="refresh-btn" class="icon-btn" title="Refresh state" style="display: none;">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg>
    </button>
  </div>

  <div id="stores-list">
    <div class="no-stores">Not connected to a running Orbit application. Start a debug session to inspect state.</div>
  </div>

  <script>
    const vscode = acquireVsCodeApi();
    let socket = null;
    let isolateId = null;
    let currentStores = {};

    window.addEventListener('DOMContentLoaded', () => {
      vscode.postMessage({ command: 'ready' });
      updateUI();
    });

    window.addEventListener('message', event => {
      const message = event.data;
      if (message.command === 'connect') {
        document.getElementById('manual-uri').value = message.uri;
        connect(message.uri);
      } else if (message.command === 'disconnect') {
        disconnect();
      }
    });

    document.getElementById('connect-btn').addEventListener('click', () => {
      const uri = document.getElementById('manual-uri').value.trim();
      if (uri) connect(uri);
    });

    document.getElementById('refresh-btn').addEventListener('click', () => {
      fetchStores();
    });

    function disconnect() {
      if (socket) {
        socket.close();
        socket = null;
      }
      isolateId = null;
      currentStores = {};
      updateUI();
    }

    function connect(uri) {
      disconnect();
      
      let wsUri = uri.replace(/^http/, 'ws');
      if (!wsUri.endsWith('/ws')) {
        wsUri = wsUri.endsWith('/') ? wsUri + 'ws' : wsUri + '/ws';
      }

      setStatus('Connecting...', 'connecting');

      try {
        socket = new WebSocket(wsUri);

        socket.onopen = () => {
          setStatus('Connected', 'connected');
          socket.send(JSON.stringify({
            jsonrpc: '2.0',
            method: 'getVM',
            params: {},
            id: 'getVM'
          }));
          socket.send(JSON.stringify({
            jsonrpc: '2.0',
            method: 'streamListen',
            params: { streamId: 'Extension' },
            id: 'subscribeExtension'
          }));
        };

        socket.onmessage = (event) => {
          const response = JSON.parse(event.data);
          
          if (response.id === 'getVM' && response.result) {
            const isolates = response.result.isolates;
            if (isolates && isolates.length > 0) {
              isolateId = isolates[0].id;
              fetchStores();
            }
          } else if (response.id === 'getStores' && response.result) {
            const resultData = JSON.parse(response.result.json);
            currentStores = resultData.stores || {};
            updateUI();
          }

          if (response.method === 'streamNotify' && response.params) {
            const streamId = response.params.streamId;
            const eventData = response.params.event;
            if (streamId === 'Extension' && eventData.extensionKind === 'orbit:state-changed') {
              const storeName = eventData.extensionData.store;
              const state = eventData.extensionData.state;
              if (currentStores[storeName]) {
                currentStores[storeName].state = state;
              } else {
                currentStores[storeName] = {
                  state: state,
                  isReady: true,
                  listeners: 0
                };
              }
              updateUI();
            }
          }
        };

        socket.onerror = (err) => {
          setStatus('Connection Error', 'error');
        };

        socket.onclose = () => {
          setStatus('Disconnected', 'disconnected');
        };
      } catch (e) {
        setStatus('Connection Failed', 'error');
      }
    }

    function fetchStores() {
      if (socket && isolateId) {
        socket.send(JSON.stringify({
          jsonrpc: '2.0',
          method: 'ext.orbit.getStores',
          params: { isolateId: isolateId },
          id: 'getStores'
        }));
      }
    }

    function setStatus(text, className) {
      const indicator = document.getElementById('status-indicator');
      const statusText = document.getElementById('status-text');
      indicator.className = 'indicator ' + className;
      statusText.innerText = text;
    }

    function updateUI() {
      const container = document.getElementById('stores-list');
      const refreshBtn = document.getElementById('refresh-btn');
      
      if (!socket || socket.readyState !== WebSocket.OPEN) {
        container.innerHTML = '<div class="no-stores">Not connected to a running Orbit application. Start a debug session to inspect state.</div>';
        refreshBtn.style.display = 'none';
        return;
      }

      refreshBtn.style.display = 'block';

      const storeNames = Object.keys(currentStores);
      if (storeNames.length === 0) {
        container.innerHTML = '<div class="no-stores">Connected, but no active stores found in registry. Instantiate stores via Orbit.use() to view them here.</div>';
        return;
      }

      let html = '';
      for (const name of storeNames) {
        const store = currentStores[name];
        html += \`
          <div class="store-card">
            <div class="store-header">
              <span class="store-name">\${name}</span>
              <div class="badges">
                <span class="badge ready">\${store.isReady ? 'Ready' : 'Not Ready'}</span>
                <span class="badge">Listeners: \${store.listeners}</span>
              </div>
            </div>
            <div class="store-body">
              \${renderState(store.state)}
            </div>
          </div>
        \`;
      }
      container.innerHTML = html;
    }

    function renderState(state) {
      if (!state || Object.keys(state).length === 0) {
        return '<em>Empty state</em>';
      }
      let html = '<div class="state-tree">';
      for (const [key, val] of Object.entries(state)) {
        html += \`
          <div class="state-row">
            <span class="state-key">\${key}</span>
            <span>\${formatValue(val)}</span>
          </div>
        \`;
      }
      html += '</div>';
      return html;
    }

    function formatValue(val) {
      if (typeof val === 'string') {
        return \`<span class="state-val-string">"\${val}"</span>\`;
      }
      if (typeof val === 'number') {
        return \`<span class="state-val-num">\${val}</span>\`;
      }
      if (typeof val === 'boolean') {
        return \`<span class="state-val-bool">\${val}</span>\`;
      }
      if (val === null) {
        return '<span class="state-val-bool">null</span>';
      }
      if (Array.isArray(val)) {
        return \`<span class="state-val-string">[\${val.length} items]</span>\`;
      }
      if (typeof val === 'object') {
        return '<span class="state-val-string">{object}</span>';
      }
      return String(val);
    }
  </script>
</body>
</html>`;
  }
}

module.exports = {
  activate,
  deactivate
};
