const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const net = require('net');
const crypto = require('crypto');

function getNonce() {
  let text = '';
  const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 32; i++) {
    text += possible.charAt(Math.floor(Math.random() * possible.length));
  }
  return text;
}

function parseStoreName(input) {
  let clean = input.trim();
  clean = clean.replace(/(?:_|-|\s)?store$/i, '');
  if (!clean) clean = 'Custom';
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

// ---------------------------------------------------------------------------
// Minimal WebSocket client — runs in Node.js extension host.
// ---------------------------------------------------------------------------

function normalizeWsUri(rawUri) {
  let uri = rawUri.trim();
  if (uri.startsWith('http://'))       uri = 'ws://'  + uri.slice(7);
  else if (uri.startsWith('https://')) uri = 'wss://' + uri.slice(8);
  else if (!uri.startsWith('ws://') && !uri.startsWith('wss://')) uri = 'ws://' + uri;
  if (!uri.endsWith('/ws')) uri = uri.endsWith('/') ? uri + 'ws' : uri + '/ws';
  return uri;
}

function parseWsUrl(rawUri) {
  let uri = rawUri.trim();
  let secure = false;
  if (uri.startsWith('wss://')) { secure = true; uri = uri.slice(6); }
  else if (uri.startsWith('ws://')) { uri = uri.slice(5); }
  const slashIdx = uri.indexOf('/');
  const hostPart = slashIdx === -1 ? uri : uri.slice(0, slashIdx);
  const urlPath  = slashIdx === -1 ? '/' : uri.slice(slashIdx);
  const colonIdx = hostPart.lastIndexOf(':');
  let host = hostPart, port = secure ? 443 : 80;
  if (colonIdx !== -1) {
    host = hostPart.slice(0, colonIdx);
    port = parseInt(hostPart.slice(colonIdx + 1), 10) || port;
  }
  return { host, port, path: urlPath, secure };
}

function decodeFrame(buf, offset = 0) {
  if (buf.length - offset < 2) return null;
  const b0 = buf[offset], b1 = buf[offset + 1];
  const fin = (b0 & 0x80) !== 0;
  const opcode = b0 & 0x0f;
  const masked = (b1 & 0x80) !== 0;
  let payloadLen = b1 & 0x7f;
  let headerLen = 2;
  if (payloadLen === 126) {
    if (buf.length - offset < 4) return null;
    payloadLen = buf.readUInt16BE(offset + 2);
    headerLen = 4;
  } else if (payloadLen === 127) {
    if (buf.length - offset < 10) return null;
    payloadLen = Number(buf.readBigUInt64BE(offset + 2));
    headerLen = 10;
  }
  if (masked) headerLen += 4;
  if (buf.length - offset < headerLen + payloadLen) return null;
  let payload = buf.slice(offset + headerLen, offset + headerLen + payloadLen);
  if (masked) {
    const maskKey = buf.slice(offset + headerLen - 4, offset + headerLen);
    payload = Buffer.from(payload);
    for (let i = 0; i < payload.length; i++) payload[i] ^= maskKey[i % 4];
  }
  return { fin, opcode, payload, totalLength: headerLen + payloadLen };
}

function encodeFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const maskKey = crypto.randomBytes(4);
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= maskKey[i % 4];
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, 0x80 | payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81; header[1] = 0xfe;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81; header[1] = 0xff;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, maskKey, masked]);
}

class WsClient {
  constructor() {
    this._socket = null;
    this._buf = Buffer.alloc(0);
    this._open = false;
    this._handlers = { open: [], message: [], error: [], close: [] };
  }
  on(event, fn) { this._handlers[event].push(fn); return this; }
  _emit(event, ...args) { this._handlers[event].forEach(fn => fn(...args)); }

  connect(rawUri) {
    this.destroy();
    const uri = normalizeWsUri(rawUri);
    const { host, port, path: urlPath } = parseWsUrl(uri);
    const wsKey = crypto.randomBytes(16).toString('base64');

    this._socket = net.createConnection({ host, port }, () => {
      const req =
        `GET ${urlPath} HTTP/1.1\r\n` +
        `Host: ${host}:${port}\r\n` +
        `Upgrade: websocket\r\n` +
        `Connection: Upgrade\r\n` +
        `Sec-WebSocket-Key: ${wsKey}\r\n` +
        `Sec-WebSocket-Version: 13\r\n\r\n`;
      this._socket.write(req);
    });

    let handshakeDone = false;
    this._socket.on('data', (chunk) => {
      this._buf = Buffer.concat([this._buf, chunk]);
      if (!handshakeDone) {
        const headerEnd = this._buf.indexOf('\r\n\r\n');
        if (headerEnd === -1) return;
        const headerStr = this._buf.slice(0, headerEnd).toString('utf8');
        this._buf = this._buf.slice(headerEnd + 4);
        if (!/^HTTP\/1\.1 101/i.test(headerStr)) {
          this._emit('error', new Error('Handshake failed: ' + headerStr.split('\r\n')[0]));
          this.destroy();
          return;
        }
        handshakeDone = true;
        this._open = true;
        this._emit('open');
        this._processFrames();
        return;
      }
      this._processFrames();
    });

    this._socket.on('error', (err) => this._emit('error', err));
    this._socket.on('close', () => { this._open = false; this._emit('close', 1006, ''); });
  }

  _processFrames() {
    let offset = 0;
    while (true) {
      const frame = decodeFrame(this._buf, offset);
      if (!frame) break;
      offset += frame.totalLength;
      if (frame.opcode === 0x8) {
        const code   = frame.payload.length >= 2 ? frame.payload.readUInt16BE(0) : 1000;
        const reason = frame.payload.length > 2  ? frame.payload.slice(2).toString('utf8') : '';
        this._open = false;
        this._emit('close', code, reason);
        this.destroy();
        break;
      } else if (frame.opcode === 0x1 || frame.opcode === 0x0) {
        this._emit('message', frame.payload.toString('utf8'));
      }
    }
    this._buf = this._buf.slice(offset);
  }

  send(text) {
    if (this._open && this._socket) this._socket.write(encodeFrame(text));
  }

  destroy() {
    if (this._socket) { try { this._socket.destroy(); } catch (_) {} this._socket = null; }
    this._open = false;
    this._buf = Buffer.alloc(0);
  }

  get isOpen() { return this._open; }
}

// ---------------------------------------------------------------------------

function activate(context) {
  let disposable = vscode.commands.registerCommand('orbit.createStore', async (uri) => {
    const inputName = await vscode.window.showInputBox({
      prompt: 'Enter OrbitStore name (e.g. User, Cart, UserProfile)',
      placeHolder: 'User',
      validateInput: (value) => {
        if (!value || value.trim().length === 0) return 'Store name cannot be empty';
        if (!/^[a-zA-Z0-9_\-\s]+$/.test(value.trim())) return 'Store name can only contain letters, numbers, spaces, underscores, and hyphens';
        return null;
      }
    });
    if (!inputName) return;
    const { pascalName, camelRef, fileName } = parseStoreName(inputName);
    let targetDir;
    if (uri && uri.fsPath) {
      const stats = fs.statSync(uri.fsPath);
      targetDir = stats.isDirectory() ? uri.fsPath : path.dirname(uri.fsPath);
    } else if (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
      targetDir = path.join(vscode.workspace.workspaceFolders[0].uri.fsPath, 'lib');
      if (!fs.existsSync(targetDir)) targetDir = vscode.workspace.workspaceFolders[0].uri.fsPath;
    } else {
      vscode.window.showErrorMessage('No active folder or workspace found.');
      return;
    }
    const filePath = path.join(targetDir, fileName);
    if (fs.existsSync(filePath)) {
      vscode.window.showErrorMessage(`File ${fileName} already exists at destination.`);
      return;
    }
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

  const provider = new OrbitStateWebviewProvider(context.extensionUri);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('orbit.stateInspector', provider)
  );

  const checkActiveSessionUri = async (session) => {
    if (!session) return;
    try {
      const customResponse = await session.customRequest('vmServiceUri').catch(() => null);
      if (customResponse && (customResponse.vmServiceUri || customResponse.uri)) {
        provider.setVmServiceUri((customResponse.vmServiceUri || customResponse.uri).toString());
        return;
      }
    } catch (_) {}
    try {
      if (session.configuration) {
        const config = session.configuration;
        const uri = config.vmServiceUri || config.observatoryUri || config.vmserviceUri;
        if (uri) { provider.setVmServiceUri(uri.toString()); return; }
      }
    } catch (_) {}
  };

  if (vscode.debug.activeDebugSession) checkActiveSessionUri(vscode.debug.activeDebugSession);

  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((e) => {
      if (e.event === 'dart.debuggerUris' && e.body) {
        const vmServiceUri = e.body.vmServiceUri || e.body.observatoryUri;
        if (vmServiceUri) provider.setVmServiceUri(vmServiceUri.toString());
      }
    })
  );

  context.subscriptions.push(
    vscode.debug.onDidStartDebugSession(async (session) => {
      checkActiveSessionUri(session);
      setTimeout(() => checkActiveSessionUri(session), 1500);
      setTimeout(() => checkActiveSessionUri(session), 3000);
      setTimeout(() => checkActiveSessionUri(session), 5000);
      setTimeout(() => checkActiveSessionUri(session), 8000);
    })
  );

  context.subscriptions.push(
    vscode.debug.onDidChangeActiveDebugSession((session) => {
      if (session) {
        checkActiveSessionUri(session);
        setTimeout(() => checkActiveSessionUri(session), 1500);
      } else {
        provider.clearVmServiceUri();
      }
    })
  );

  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession(() => provider.clearVmServiceUri())
  );
}

function deactivate() {}

// ---------------------------------------------------------------------------
// OrbitStateWebviewProvider
// All VM-service protocol logic lives here in Node.js.
// The webview only renders data pushed to it.
// ---------------------------------------------------------------------------

class OrbitStateWebviewProvider {
  constructor(extensionUri) {
    this._extensionUri = extensionUri;
    this._view = undefined;
    this._vmServiceUri = undefined;
    this._ws = null;
    this._isolateId = null;
    this._currentStores = {};
    this._connected = false;
    this._connectedUri = '';
    this._fetchRetries = 0;
  }

  resolveWebviewView(webviewView) {
    this._view = webviewView;
    webviewView.webview.options = { enableScripts: true, localResourceRoots: [this._extensionUri] };
    webviewView.webview.html = this._getHtmlForWebview(webviewView.webview);

    webviewView.webview.onDidReceiveMessage(message => {
      switch (message.command) {
        case 'ready':
          // Push current state to newly-opened webview
          this._pushConnectionState();
          if (this._connected) {
            this._pushStores();
          }
          break;
        case 'connectRequest':
          this._connectWs(message.uri);
          break;
        case 'disconnectRequest':
          this._disconnectWs();
          break;
        case 'fetchStores':
          this._fetchStores();
          break;
      }
    });
  }

  setVmServiceUri(uri) {
    if (!uri) return;
    this._vmServiceUri = typeof uri === 'string' ? uri : uri.toString();
    // Connect immediately from Node.js
    this._connectWs(this._vmServiceUri);
  }

  clearVmServiceUri() {
    this._vmServiceUri = undefined;
    this._disconnectWs();
  }

  // ---- WebSocket management ----

  _connectWs(rawUri) {
    this._disconnectWs();
    this._connectedUri = normalizeWsUri(rawUri);
    this._isolateId = null;
    this._currentStores = {};

    this._postToView({ command: 'status', state: 'connecting', uri: this._connectedUri });

    this._ws = new WsClient();

    this._ws.on('open', () => {
      this._connected = true;
      this._fetchRetries = 0;
      this._postToView({ command: 'status', state: 'connected', uri: this._connectedUri });
      // Kick off the VM-service protocol entirely from Node.js
      this._wsSend({ jsonrpc: '2.0', method: 'getVM', params: {}, id: 'getVM' });
      this._wsSend({ jsonrpc: '2.0', method: 'streamListen', params: { streamId: 'Extension' }, id: 'subExt' });
    });

    this._ws.on('message', (data) => this._handleVmMessage(data));

    this._ws.on('error', (err) => {
      this._connected = false;
      this._postToView({ command: 'status', state: 'error', message: err.message });
    });

    this._ws.on('close', (code, reason) => {
      this._connected = false;
      this._isolateId = null;
      this._postToView({ command: 'status', state: 'disconnected', code, reason });
    });

    this._ws.connect(rawUri);
  }

  _disconnectWs() {
    if (this._ws) { this._ws.destroy(); this._ws = null; }
    this._connected = false;
    this._isolateId = null;
    this._currentStores = {};
    this._postToView({ command: 'status', state: 'disconnected', code: 1000, reason: '' });
    this._pushStores();
  }

  _wsSend(obj) {
    if (this._ws && this._ws.isOpen) this._ws.send(JSON.stringify(obj));
  }

  _handleVmMessage(raw) {
    let response;
    try { response = JSON.parse(raw); } catch (_) { return; }

    // getVM response → grab first isolate ID → fetch stores
    if (response.id === 'getVM' && response.result) {
      const isolates = response.result.isolates || [];
      if (isolates.length > 0) {
        this._isolateId = isolates[0].id;
        this._fetchStores();
      } else {
        // Isolate not ready yet — retry
        setTimeout(() => this._wsSend({ jsonrpc: '2.0', method: 'getVM', params: {}, id: 'getVM' }), 1000);
      }
    }

    // getStores response
    if (response.id === 'getStores') {
      if (response.result) {
        try {
          const raw = response.result;
          let storeData = raw;
          if (typeof raw.json === 'string') storeData = JSON.parse(raw.json);
          else if (raw.json && typeof raw.json === 'object') storeData = raw.json;
          this._currentStores = storeData.stores || {};
        } catch (_) {
          this._currentStores = {};
        }

        if (Object.keys(this._currentStores).length === 0 && this._fetchRetries < 5) {
          // Stores not yet registered — retry with backoff (1s, 2s, 4s, 8s, 16s)
          const delay = Math.pow(2, this._fetchRetries) * 1000;
          this._fetchRetries++;
          setTimeout(() => this._fetchStores(), delay);
        } else {
          this._fetchRetries = 0;
          this._pushStores();
        }
      } else if (response.error) {
        // Extension method not yet registered — retry
        setTimeout(() => this._fetchStores(), 1500);
      }
    }

    // Real-time state change events
    if (response.method === 'streamNotify' && response.params) {
      const { streamId, event: eventData } = response.params;
      if (streamId === 'Extension' && eventData && eventData.extensionKind === 'orbit:state-changed') {
        // Always re-fetch full store list on any state change event.
        // This handles cases where new stores appear or the initial fetch was empty.
        this._fetchRetries = 0;
        this._fetchStores();
      }
    }
  }

  _fetchStores() {
    if (this._isolateId) {
      this._wsSend({
        jsonrpc: '2.0',
        method: 'ext.orbit.getStores',
        params: { isolateId: this._isolateId },
        id: 'getStores'
      });
    }
  }

  _pushConnectionState() {
    const state = this._connected ? 'connected' : 'disconnected';
    this._postToView({ command: 'status', state, uri: this._connectedUri });
  }

  _pushStores() {
    this._postToView({ command: 'stores', stores: this._currentStores });
  }

  _postToView(msg) {
    if (this._view) this._view.webview.postMessage(msg);
  }

  // ---- HTML ----

  _getHtmlForWebview(webview) {
    const nonce = getNonce();
    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; font-src ${webview.cspSource} https:; script-src 'nonce-${nonce}';">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      margin: 0; padding: 14px;
      color: var(--vscode-sideBar-foreground, var(--vscode-foreground, #cccccc));
      background-color: var(--vscode-sideBar-background, #181818);
      font-size: 12px; line-height: 1.4;
    }
    .brand-header {
      display: flex; align-items: center; justify-content: space-between;
      margin-bottom: 14px; padding-bottom: 10px;
      border-bottom: 1px solid var(--vscode-sideBar-border, rgba(128,128,128,0.2));
    }
    .brand-title {
      display: flex; align-items: center; gap: 8px;
      font-weight: 700; font-size: 14px; letter-spacing: 0.5px;
      color: var(--vscode-textLink-foreground, #3794ff);
    }
    .status-badge {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 3px 8px; border-radius: 12px;
      background: var(--vscode-badge-background, rgba(128,128,128,0.15));
      color: var(--vscode-badge-foreground, inherit);
      border: 1px solid var(--vscode-widget-border, rgba(128,128,128,0.2));
      font-size: 11px; font-weight: 600;
    }
    .indicator {
      width: 8px; height: 8px; border-radius: 50%;
      background-color: #888; transition: all 0.3s ease;
    }
    .indicator.connected    { background-color: #10b981; box-shadow: 0 0 8px #10b981; }
    .indicator.connecting   { background-color: #f59e0b; box-shadow: 0 0 8px #f59e0b; }
    .indicator.disconnected { background-color: #888; }
    .indicator.error        { background-color: #ef4444; }
    .connection-panel {
      background: var(--vscode-welcomePage-tileBackground, rgba(128,128,128,0.08));
      border: 1px solid var(--vscode-widget-border, rgba(128,128,128,0.15));
      border-radius: 8px; padding: 10px 12px; margin-bottom: 14px;
    }
    .panel-label {
      font-size: 11px; color: var(--vscode-descriptionForeground, rgba(128,128,128,0.8));
      margin-bottom: 6px; text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600;
    }
    .input-group { display: flex; gap: 6px; }
    input[type="text"] {
      flex: 1;
      background: var(--vscode-input-background, rgba(0,0,0,0.1));
      border: 1px solid var(--vscode-input-border, rgba(128,128,128,0.2));
      border-radius: 4px; color: var(--vscode-input-foreground, inherit);
      padding: 6px 10px; font-size: 11px; font-family: inherit; transition: all 0.2s ease;
    }
    input[type="text"]:focus {
      outline: none; border-color: var(--vscode-focusBorder, #007fd4);
      box-shadow: 0 0 0 2px rgba(0,127,212,0.3);
    }
    button {
      background: var(--vscode-button-background, #007fd4);
      color: var(--vscode-button-foreground, #fff);
      border: none; padding: 6px 12px; border-radius: 4px;
      cursor: pointer; font-family: inherit; font-weight: 600;
      font-size: 11px; transition: all 0.2s ease;
    }
    button:hover { background: var(--vscode-button-hoverBackground, #0062a3); transform: translateY(-1px); }
    #debug-info {
      display: none; margin-top: 8px; font-size: 10px;
      color: var(--vscode-descriptionForeground, #888);
      word-break: break-all; white-space: pre-wrap;
    }
    .store-card {
      background: var(--vscode-welcomePage-tileBackground, rgba(128,128,128,0.05));
      border: 1px solid var(--vscode-widget-border, rgba(128,128,128,0.15));
      border-radius: 8px; margin-bottom: 10px; overflow: hidden; transition: all 0.2s ease;
    }
    .store-card:hover {
      border-color: var(--vscode-focusBorder, #007fd4);
      box-shadow: 0 4px 12px rgba(0,0,0,0.1);
    }
    .store-header {
      padding: 10px 12px;
      background: var(--vscode-sideBarSectionHeader-background, rgba(128,128,128,0.08));
      display: flex; justify-content: space-between; align-items: center;
      border-bottom: 1px solid var(--vscode-widget-border, rgba(128,128,128,0.1));
    }
    .store-name { font-weight: 700; font-size: 13px; color: var(--vscode-textLink-foreground, #007fd4); letter-spacing: 0.2px; }
    .badges { display: flex; gap: 4px; }
    .badge {
      font-size: 10px; padding: 2px 8px; border-radius: 12px;
      background: var(--vscode-badge-background, rgba(128,128,128,0.15));
      color: var(--vscode-badge-foreground, inherit); font-weight: 600;
    }
    .badge.ready { background: rgba(16,185,129,0.15); color: #10b981; border: 1px solid rgba(16,185,129,0.3); }
    .store-body { padding: 10px 12px; }
    .state-tree { display: flex; flex-direction: column; gap: 4px; }
    .state-row {
      display: flex; justify-content: space-between; align-items: center;
      border-bottom: 1px solid var(--vscode-widget-border, rgba(128,128,128,0.08)); padding: 3px 0;
    }
    .state-key {
      color: var(--vscode-symbolIcon-propertyForeground, #007fd4);
      font-family: var(--vscode-editor-font-family, monospace); font-weight: 600; font-size: 11px;
    }
    .state-val-string { color: var(--vscode-debugTokenExpression-string, #a31515); font-family: monospace; font-size: 11px; }
    .state-val-num    { color: var(--vscode-debugTokenExpression-number, #098658); font-family: monospace; font-weight: 600; font-size: 11px; }
    .state-val-bool   { color: var(--vscode-debugTokenExpression-boolean, #0000ff); font-family: monospace; font-weight: 600; font-size: 11px; }
    .no-stores { text-align: center; color: var(--vscode-descriptionForeground, rgba(128,128,128,0.7)); padding: 24px 12px; font-size: 12px; }
    .refresh-container { display: flex; justify-content: flex-end; margin-bottom: 8px; }
    .icon-btn {
      background: var(--vscode-toolbar-hoverBackground, rgba(128,128,128,0.1));
      padding: 5px; border: 1px solid var(--vscode-widget-border, rgba(128,128,128,0.15));
      border-radius: 4px; display: inline-flex; align-items: center; justify-content: center;
      cursor: pointer; color: var(--vscode-icon-foreground, inherit); transition: all 0.2s ease;
    }
    .icon-btn:hover { background: var(--vscode-toolbar-activeBackground, rgba(128,128,128,0.2)); transform: rotate(45deg); }
  </style>
</head>
<body>
  <div class="brand-header">
    <div class="brand-title">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="url(#og)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <defs><linearGradient id="og" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" stop-color="#3794ff"/><stop offset="100%" stop-color="#a855f7"/></linearGradient></defs>
        <circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 9 9"/>
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
    <div id="debug-info"></div>
  </div>

  <div class="refresh-container">
    <button id="refresh-btn" class="icon-btn" title="Refresh state" style="display:none;">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg>
    </button>
  </div>

  <div id="stores-list">
    <div class="no-stores">Not connected to a running Orbit application. Start a debug session to inspect state.</div>
  </div>

  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    let connected = false;
    let currentStores = {};

    window.addEventListener('DOMContentLoaded', () => {
      vscode.postMessage({ command: 'ready' });
    });

    // All messages come from the extension host (Node.js)
    window.addEventListener('message', event => {
      const msg = event.data;
      switch (msg.command) {
        case 'status':
          handleStatus(msg);
          break;
        case 'stores':
          currentStores = msg.stores || {};
          renderStores();
          break;
      }
    });

    function handleStatus(msg) {
      switch (msg.state) {
        case 'connecting':
          connected = false;
          setStatus('Connecting...', 'connecting');
          showDebug('→ ' + (msg.uri || ''));
          break;
        case 'connected':
          connected = true;
          setStatus('Connected', 'connected');
          showDebug('✓ Connected to ' + (msg.uri || ''));
          renderStores();
          break;
        case 'error':
          connected = false;
          setStatus('Error', 'error');
          showDebug('✗ ' + (msg.message || 'Connection error'));
          renderStores();
          break;
        case 'disconnected':
          connected = false;
          currentStores = {};
          setStatus('Disconnected', 'disconnected');
          if (msg.code && msg.code !== 1000) showDebug('✗ Closed (' + msg.code + '): ' + (msg.reason || ''));
          renderStores();
          break;
      }
    }

    document.getElementById('connect-btn').addEventListener('click', () => {
      const uri = document.getElementById('manual-uri').value.trim();
      if (uri) vscode.postMessage({ command: 'connectRequest', uri });
    });

    document.getElementById('manual-uri').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        const uri = document.getElementById('manual-uri').value.trim();
        if (uri) vscode.postMessage({ command: 'connectRequest', uri });
      }
    });

    document.getElementById('refresh-btn').addEventListener('click', () => {
      vscode.postMessage({ command: 'fetchStores' });
    });

    function setStatus(text, cls) {
      document.getElementById('status-indicator').className = 'indicator ' + cls;
      document.getElementById('status-text').innerText = text;
    }

    function showDebug(msg) {
      const el = document.getElementById('debug-info');
      el.style.display = 'block';
      el.textContent = msg;
    }

    function renderStores() {
      const container = document.getElementById('stores-list');
      const refreshBtn = document.getElementById('refresh-btn');

      if (!connected) {
        container.innerHTML = '<div class="no-stores">Not connected to a running Orbit application. Start a debug session to inspect state.</div>';
        refreshBtn.style.display = 'none';
        return;
      }

      refreshBtn.style.display = 'block';
      const storeNames = Object.keys(currentStores);
      if (storeNames.length === 0) {
        container.innerHTML = '<div class="no-stores">Connected — waiting for stores. Make sure Orbit.use() is called and the app is fully initialized.</div>';
        return;
      }

      let html = '';
      for (const name of storeNames) {
        const store = currentStores[name];
        const scopedBadge = store.isScoped
          ? '<span class="badge" style="background:rgba(168,85,247,0.15);color:#c084fc;border:1px solid rgba(168,85,247,0.3)">Scoped</span>'
          : '<span class="badge" style="background:rgba(55,148,255,0.15);color:#60a5fa;border:1px solid rgba(55,148,255,0.3)">Global</span>';
        html += \`<div class="store-card">
          <div class="store-header">
            <span class="store-name">\${esc(name)}</span>
            <div class="badges">
              \${scopedBadge}
              <span class="badge ready">\${store.isReady ? 'Ready' : 'Not Ready'}</span>
              <span class="badge">Listeners: \${store.listeners}</span>
            </div>
          </div>
          <div class="store-body">\${renderState(store.state)}</div>
        </div>\`;
      }
      container.innerHTML = html;
    }

    function renderState(state) {
      if (!state || typeof state !== 'object' || Object.keys(state).length === 0) return '<em>Empty state</em>';
      let html = '<div class="state-tree">';
      for (const [k, v] of Object.entries(state)) html += renderItem(k, v);
      html += '</div>';
      return html;
    }

    function renderItem(key, val) {
      const escapedKey = esc(key);
      if (val !== null && typeof val === 'object') {
        const isArray = Array.isArray(val);
        const entries = Object.entries(val);
        const label = isArray ? \`List (\${entries.length})\` : \`Map (\${entries.length})\`;
        return \`<details open style="margin-left:8px;margin-top:4px">
          <summary class="state-row" style="cursor:pointer;user-select:none">
            <span class="state-key">\${escapedKey}: <span style="opacity:0.7;font-size:11px">\${label}</span></span>
          </summary>
          <div style="padding-left:12px;border-left:1px dashed rgba(128,128,128,0.3);margin-top:4px">
            \${entries.length === 0 ? '<em>Empty</em>' : entries.map(([k,v]) => renderItem(isArray ? \`[\${k}]\` : k, v)).join('')}
          </div></details>\`;
      }
      return \`<div class="state-row"><span class="state-key">\${escapedKey}</span><span>\${fmtVal(val)}</span></div>\`;
    }

    function fmtVal(val) {
      if (typeof val === 'string')  return \`<span class="state-val-string">"\${esc(val)}"</span>\`;
      if (typeof val === 'number')  return \`<span class="state-val-num">\${val}</span>\`;
      if (typeof val === 'boolean') return \`<span class="state-val-bool">\${val}</span>\`;
      if (val === null || val === undefined) return '<span class="state-val-bool">null</span>';
      return esc(String(val));
    }

    function esc(s) {
      return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#039;');
    }
  </script>
</body>
</html>`;
  }
}

module.exports = { activate, deactivate };
