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
    * { box-sizing: border-box; }
    body {
      font-family: 'Outfit', -apple-system, BlinkMacSystemFont, sans-serif;
      margin: 0;
      padding: 14px;
      color: var(--vscode-foreground, #cccccc);
      background-color: var(--vscode-sideBar-background, #181818);
      font-size: 12px;
      line-height: 1.4;
    }
    
    .brand-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 14px;
      padding-bottom: 10px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    }

    .brand-title {
      display: flex;
      align-items: center;
      gap: 8px;
      font-weight: 700;
      font-size: 14px;
      letter-spacing: 0.5px;
      background: linear-gradient(135deg, #3794ff 0%, #a855f7 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }

    .status-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 3px 8px;
      border-radius: 12px;
      background: rgba(255, 255, 255, 0.04);
      border: 1px solid rgba(255, 255, 255, 0.06);
      font-size: 11px;
      font-weight: 600;
    }
    
    .indicator {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background-color: #888;
      transition: all 0.3s ease;
    }
    
    .indicator.connected { background-color: #10b981; box-shadow: 0 0 10px #10b981; }
    .indicator.connecting { background-color: #f59e0b; box-shadow: 0 0 10px #f59e0b; }
    .indicator.disconnected { background-color: #ef4444; }
    .indicator.error { background-color: #ef4444; }
    
    .connection-panel {
      background: rgba(255, 255, 255, 0.03);
      backdrop-filter: blur(8px);
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 10px;
      padding: 10px 12px;
      margin-bottom: 14px;
    }

    .panel-label {
      font-size: 11px;
      color: rgba(255, 255, 255, 0.6);
      margin-bottom: 6px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      font-weight: 600;
    }
    
    .input-group {
      display: flex;
      gap: 6px;
    }
    
    input[type="text"] {
      flex: 1;
      background: rgba(0, 0, 0, 0.3);
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 6px;
      color: #fff;
      padding: 6px 10px;
      font-size: 11px;
      font-family: inherit;
      transition: all 0.2s ease;
    }
    
    input[type="text"]:focus {
      outline: none;
      border-color: #3794ff;
      box-shadow: 0 0 0 2px rgba(55, 148, 255, 0.2);
    }
    
    button {
      background: linear-gradient(135deg, #007fd4 0%, #005fb8 100%);
      color: #ffffff;
      border: none;
      padding: 6px 12px;
      border-radius: 6px;
      cursor: pointer;
      font-family: inherit;
      font-weight: 600;
      font-size: 11px;
      transition: all 0.2s ease;
      box-shadow: 0 2px 6px rgba(0, 0, 0, 0.2);
    }
    
    button:hover {
      opacity: 0.9;
      transform: translateY(-1px);
    }
    
    .store-card {
      background: rgba(255, 255, 255, 0.03);
      border: 1px solid rgba(255, 255, 255, 0.07);
      border-radius: 10px;
      margin-bottom: 10px;
      overflow: hidden;
      transition: all 0.2s ease;
    }
    
    .store-card:hover {
      border-color: rgba(55, 148, 255, 0.3);
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.25);
    }
    
    .store-header {
      padding: 10px 12px;
      background: rgba(255, 255, 255, 0.02);
      display: flex;
      justify-content: space-between;
      align-items: center;
      border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    }
    
    .store-name {
      font-weight: 700;
      font-size: 13px;
      color: #60a5fa;
      letter-spacing: 0.2px;
    }
    
    .badges {
      display: flex;
      gap: 4px;
    }
    
    .badge {
      font-size: 10px;
      padding: 2px 8px;
      border-radius: 12px;
      background: rgba(255, 255, 255, 0.06);
      color: rgba(255, 255, 255, 0.7);
      font-weight: 600;
    }
    
    .badge.ready {
      background: rgba(16, 185, 129, 0.15);
      color: #34d399;
      border: 1px solid rgba(16, 185, 129, 0.2);
    }
    
    .store-body {
      padding: 10px 12px;
    }
    
    .state-tree {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    
    .state-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      border-bottom: 1px solid rgba(255, 255, 255, 0.03);
      padding: 3px 0;
    }
    
    .state-key {
      color: #93c5fd;
      font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
      font-weight: 600;
      font-size: 11px;
    }
    
    .state-val-string {
      color: #fca5a5;
      font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
      font-size: 11px;
    }
    
    .state-val-num {
      color: #86efac;
      font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
      font-weight: 600;
      font-size: 11px;
    }
    
    .state-val-bool {
      color: #c084fc;
      font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
      font-weight: 600;
      font-size: 11px;
    }
    
    .no-stores {
      text-align: center;
      color: rgba(255, 255, 255, 0.4);
      padding: 24px 12px;
      font-size: 12px;
    }
    
    .refresh-container {
      display: flex;
      justify-content: flex-end;
      margin-bottom: 8px;
    }
    
    .icon-btn {
      background: rgba(255, 255, 255, 0.05);
      padding: 5px;
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 6px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      color: var(--vscode-foreground, #cccccc);
      transition: all 0.2s ease;
    }
    
    .icon-btn:hover {
      background: rgba(255, 255, 255, 0.12);
      transform: rotate(45deg);
    }
  </style>
</head>
<body>
  <div class="brand-header">
    <div class="brand-title">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="url(#orbit-grad)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <defs>
          <linearGradient id="orbit-grad" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stop-color="#3794ff"/>
            <stop offset="100%" stop-color="#a855f7"/>
          </linearGradient>
        </defs>
        <circle cx="12" cy="12" r="9"/>
        <path d="M12 3a9 9 0 0 1 9 9"/>
      </svg>
      Orbit Inspector
    </div>
    <div class="status-badge">
      <div id="status-indicator" class="indicator disconnected"></div>
      <span id="status-text">Disconnected</span>
    </div>
  </div>

  <div class="connection-panel">
    <div class="panel-label">Dart VM Service Connection</div>
    <div class="input-group">
      <input type="text" id="manual-uri" placeholder="ws://127.0.0.1:8181/..." />
      <button id="connect-btn">Connect</button>
    </div>
  </div>

  <div class="refresh-container">
    <button id="refresh-btn" class="icon-btn" title="Refresh state" style="display: none;">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg>
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
          try {
            const response = JSON.parse(event.data);
            
            if (response.id === 'getVM' && response.result) {
              const isolates = response.result.isolates;
              if (isolates && isolates.length > 0) {
                isolateId = isolates[0].id;
                fetchStores();
              }
            } else if (response.id === 'getStores' && response.result) {
              const resultData = typeof response.result.json === 'string' 
                ? JSON.parse(response.result.json) 
                : response.result.json;
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
          } catch (e) {
            console.error('Error parsing VM Service message:', e);
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
      if (!state || typeof state !== 'object' || Object.keys(state).length === 0) {
        return '<em>Empty state</em>';
      }
      let html = '<div class="state-tree">';
      for (const [key, val] of Object.entries(state)) {
        html += renderItem(key, val);
      }
      html += '</div>';
      return html;
    }

    function renderItem(key, val) {
      const isComplex = val !== null && typeof val === 'object';
      const escapedKey = escapeHtml(key);

      if (!isComplex) {
        return \`
          <div class="state-row">
            <span class="state-key">\${escapedKey}</span>
            <span>\${formatValue(val)}</span>
          </div>
        \`;
      }

      const isArray = Array.isArray(val);
      const entries = Object.entries(val);
      const count = entries.length;
      const label = isArray ? \`List (\${count})\` : \`Map/Object (\${count})\`;

      return \`
        <details class="tree-details" open style="margin-left: 8px; margin-top: 4px;">
          <summary class="state-row" style="cursor: pointer; user-select: none;">
            <span class="state-key">\${escapedKey}: <span style="font-size: 11px; opacity: 0.7;">\${label}</span></span>
          </summary>
          <div style="padding-left: 12px; border-left: 1px dashed rgba(255, 255, 255, 0.15); margin-top: 4px;">
            \${count === 0 ? '<em>Empty</em>' : entries.map(([k, v]) => renderItem(isArray ? \`[\${k}]\` : k, v)).join('')}
          </div>
        </details>
      \`;
    }

    function formatValue(val) {
      if (typeof val === 'string') {
        return \`<span class="state-val-string">"\${escapeHtml(val)}"</span>\`;
      }
      if (typeof val === 'number') {
        return \`<span class="state-val-num">\${val}</span>\`;
      }
      if (typeof val === 'boolean') {
        return \`<span class="state-val-bool">\${val}</span>\`;
      }
      if (val === null || val === undefined) {
        return '<span class="state-val-bool">null</span>';
      }
      return escapeHtml(String(val));
    }

    function escapeHtml(str) {
      return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
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
