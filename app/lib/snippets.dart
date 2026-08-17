/// Command snippet model and persistent repository.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single command snippet configuration block.
class CommandSnippet {
  final String id;
  String name;
  String condaEnv;
  String workDir;
  String command;

  CommandSnippet({
    required this.id,
    required this.name,
    this.condaEnv = '',
    this.workDir = '',
    required this.command,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'condaEnv': condaEnv,
        'workDir': workDir,
        'command': command,
      };

  factory CommandSnippet.fromJson(Map<String, dynamic> j) => CommandSnippet(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        condaEnv: j['condaEnv'] as String? ?? '',
        workDir: j['workDir'] as String? ?? '',
        command: j['command'] as String? ?? '',
      );

  /// Compose working dir, conda activation, and command into a single executable bash command.
  /// Automatically prepends `mon run` if not already present, ensuring full background monitoring.
  String toExecutableCommand({bool withMonRun = true}) {
    final parts = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. 如果指定了工作目录: cd 到对应目录
    if (dir.isNotEmpty) {
      parts.add('cd ${dir.contains(' ') ? '"$dir"' : dir}');
    }

    // 2. 环境初始化: 模拟终端打开时的环境，确保自动加载 conda 及对应环境 (未填则默认激活 base)
    if (env.isNotEmpty) {
      parts.add(
          '(eval "\$(conda shell.bash hook 2>/dev/null)" || source "\$(conda info --base 2>/dev/null)/etc/profile.d/conda.sh" 2>/dev/null || source "\$HOME/miniconda3/etc/profile.d/conda.sh" 2>/dev/null || source "\$HOME/anaconda3/etc/profile.d/conda.sh" 2>/dev/null || true) && conda activate $env');
    } else {
      parts.add(
          '(eval "\$(conda shell.bash hook 2>/dev/null)" || source "\$(conda info --base 2>/dev/null)/etc/profile.d/conda.sh" 2>/dev/null || source "\$HOME/miniconda3/etc/profile.d/conda.sh" 2>/dev/null || source "\$HOME/anaconda3/etc/profile.d/conda.sh" 2>/dev/null || true) && (conda activate base 2>/dev/null || true)');
    }

    if (cmd.isNotEmpty) {
      if (withMonRun &&
          !cmd.startsWith('mon run') &&
          !cmd.startsWith('runmon run') &&
          !cmd.startsWith('mon wait')) {
        final taskName = name.trim().replaceAll('"', '');
        final nameArg = taskName.isNotEmpty ? '--name "$taskName" ' : '';
        cmd = 'mon run $nameArg-- $cmd';
      }
      parts.add(cmd);
    }

    return parts.join(' && ');
  }
}

/// Global snippet repository store.
class SnippetStore extends ChangeNotifier {
  final List<CommandSnippet> _snippets = [];

  List<CommandSnippet> get snippets => List.unmodifiable(_snippets);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList('saved_snippets') ?? [];
    _snippets.clear();
    for (final raw in rawList) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _snippets.add(CommandSnippet.fromJson(map));
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = _snippets.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('saved_snippets', rawList);
  }

  Future<void> addSnippet(CommandSnippet snippet) async {
    _snippets.add(snippet);
    await _persist();
    notifyListeners();
  }

  Future<void> updateSnippet(CommandSnippet snippet) async {
    final index = _snippets.indexWhere((s) => s.id == snippet.id);
    if (index >= 0) {
      _snippets[index] = snippet;
      await _persist();
      notifyListeners();
    }
  }

  Future<void> deleteSnippet(String id) async {
    _snippets.removeWhere((s) => s.id == id);
    await _persist();
    notifyListeners();
  }

  CommandSnippet? getById(String id) {
    return _snippets.where((s) => s.id == id).firstOrNull;
  }
}

final snippetStore = SnippetStore();
