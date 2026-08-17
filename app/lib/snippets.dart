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

  /// Compose root home startup, bashrc/conda activation (defaults to base), working dir, and command.
  /// Automatically prepends `mon run` if not already present, ensuring full background monitoring.
  String toExecutableCommand({bool withMonRun = true}) {
    final parts = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. 模拟服务器终端交互登录: 从家目录启动并加载 bashrc 与 conda 环境 hook
    parts.add('[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null; (eval "\$(conda shell.bash hook 2>/dev/null)" || source "\$(conda info --base 2>/dev/null)/etc/profile.d/conda.sh" 2>/dev/null || true)');

    // 2. 环境激活: 若指定了特定环境则 activate 对应环境，否则默认激活 base
    if (env.isNotEmpty) {
      parts.add('conda activate $env');
    } else {
      parts.add('(conda activate base 2>/dev/null || true)');
    }

    // 3. 切换至工作目录 (若未指定则保持在主目录)
    if (dir.isNotEmpty) {
      parts.add('cd ${dir.contains(' ') ? '"$dir"' : dir}');
    }

    // 4. 执行命令代码 (自动带有 mon run)
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
