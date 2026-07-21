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
    const storeTemplate = `import 'package:orbit/orbit.dart';

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
}

function deactivate() {}

module.exports = {
  activate,
  deactivate
};

