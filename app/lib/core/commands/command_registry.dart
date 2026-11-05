/// Command registry backing the command palette (docs/ARCHITECTURE.md §2).
///
/// Phase 1 registers only real actions (navigation, theme, demo-state).
/// Later phases contribute commands through the same registry — the palette
/// never hardcodes entries.
library;

/// A named, executable action.
final class CfCommand {
  const CfCommand({
    required this.id,
    required this.title,
    required this.category,
    required this.onExecute,
  });

  final String id;
  final String title;
  final String category;
  final void Function() onExecute;
}

/// Fuzzy subsequence match: every query character must appear in order.
/// Returns null when there is no match; higher scores are better.
int? fuzzyScore(String query, String text) {
  if (query.isEmpty) {
    return 0;
  }
  final q = query.toLowerCase();
  final t = text.toLowerCase();
  var score = 0;
  var textIndex = 0;
  var previousMatch = -2;
  for (var i = 0; i < q.length; i++) {
    final char = q[i];
    if (char == ' ') {
      continue;
    }
    final found = t.indexOf(char, textIndex);
    if (found < 0) {
      return null;
    }
    // Reward contiguous runs and word-boundary hits.
    score += (found == previousMatch + 1) ? 3 : 1;
    if (found == 0 || t[found - 1] == ' ') {
      score += 2;
    }
    previousMatch = found;
    textIndex = found + 1;
  }
  return score;
}

/// Holds commands and answers palette queries.
final class CommandRegistry {
  final Map<String, CfCommand> _commands = {};

  List<CfCommand> get commands => List.unmodifiable(_commands.values);

  void register(CfCommand command) {
    _commands[command.id] = command;
  }

  void unregister(String id) {
    _commands.remove(id);
  }

  /// Commands matching [query], best first; empty query lists everything.
  List<CfCommand> search(String query) {
    final scored = <(CfCommand, int)>[];
    for (final command in _commands.values) {
      final score = fuzzyScore(query, '${command.category} ${command.title}');
      if (score != null) {
        scored.add((command, score));
      }
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : a.$1.title.compareTo(b.$1.title);
    });
    return scored.map((e) => e.$1).toList();
  }
}
