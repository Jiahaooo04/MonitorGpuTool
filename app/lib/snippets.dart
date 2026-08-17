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

  /// Compose root home startup, conda path export & activation (defaults to base), working dir, and command.
  String toExecutableCommand({bool withMonRun = false}) {
    final parts = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. 定义并执行 conda 初始化函数 (确保退出码始终为 0，防止循环末尾返回 1 导致 && 链熔断)
    parts.add('_init_conda() { for _b in "\$HOME/miniconda3/bin" "\$HOME/anaconda3/bin" "\$HOME/miniconda/bin" "\$HOME/anaconda/bin" "/opt/conda/bin" "/root/miniconda3/bin" "/root/anaconda3/bin"; do if [ -d "\$_b" ]; then export PATH="\$_b:\$PATH"; break; fi; done; for _d in "\$HOME/miniconda3" "\$HOME/anaconda3" "\$HOME/miniconda" "\$HOME/anaconda" "/opt/conda" "/root/miniconda3" "/root/anaconda3" "\$HOME/.conda"; do if [ -f "\$_d/etc/profile.d/conda.sh" ]; then . "\$_d/etc/profile.d/conda.sh"; break; fi; done; if command -v conda >/dev/null 2>&1; then eval "\$(conda shell.bash hook 2>/dev/null)" || true; fi; return 0; }; _init_conda');

    // 2. 激活目标环境 (若指定特定环境则激活，若未指定则激活 base)
    if (env.isNotEmpty) {
      parts.add('(conda activate $env || source activate $env || true)');
    } else {
      parts.add('(conda activate base || source activate base || true)');
    }

    // 3. 切换至工作目录
    if (dir.isNotEmpty) {
      parts.add('cd ${dir.contains(' ') ? '"$dir"' : dir}');
    }

    // 4. 执行命令代码 (在蹲卡场景下由 gpuwait 统一包装 mon run，此处保持纯净命令)
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
