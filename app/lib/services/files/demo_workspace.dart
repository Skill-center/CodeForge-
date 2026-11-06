/// Seed content of the Phase 2 workspace (docs/EDITOR_ARCHITECTURE.md,
/// "Files").
library;

/// The demo project. The first run writes it to the workspace folder as
/// real files (LocalFileService); tests seed in-memory workspaces with it.
abstract final class DemoWorkspace {
  static const String id = 'demo';
  static const String displayName = 'Demo Workspace';

  static const Map<String, String> files = {
    'main.js': '''
// CodeForge demo — JavaScript
import { greet } from './utils.js';

const languages = ['JavaScript', 'Python', 'Dart'];

function main() {
  for (const lang of languages) {
    console.log(greet(lang));
  }
}

main();
''',
    'utils.js': '''
// Helpers for the demo entry point.
export function greet(language) {
  return `Hello from \${language}!`;
}
''',
    'app.py': '''
# CodeForge demo — Python
from dataclasses import dataclass


@dataclass
class Forge:
    temperature: int = 1200

    def heat(self, delta: int) -> None:
        self.temperature += delta


if __name__ == "__main__":
    forge = Forge()
    forge.heat(50)
    print(f"Forge at {forge.temperature}°C")
''',
    'README.md': '''
# Demo Workspace

A sample project, written to this device the first time CodeForge
opened it. Edits are real: Save writes them to these files. Terminals
and runtimes arrive in later phases.

- `main.js` — JavaScript entry point
- `app.py` — Python sample
- `src/` — nested folder example
''',
    'src/greeting.dart': '''
// CodeForge demo — Dart
String greet(String name) => 'Hello, \$name!';

void main() {
  print(greet('CodeForge'));
}
''',
    'src/notes.txt': 'Scratch notes live here.\n',
    '.gitignore': 'node_modules/\n__pycache__/\nbuild/\n',
    'package.json': '''
{
  "name": "codeforge-demo",
  "version": "0.1.0",
  "type": "module",
  "private": true
}
''',
  };
}
