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

  /// Compose root home startup, fault-tolerant bashrc/conda activation (defaults to base), working dir, and command.
  String toExecutableCommand({bool withMonRun = false}) {
    final initParts = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. 模拟交互终端登录: 完整加载 bashrc，并通过多路径注入 Conda 初始化
    initParts.add('source ~/.bashrc 2>/dev/null || true');
    initParts.add('for _d in "\$HOME/miniconda3" "\$HOME/anaconda3" "\$HOME/miniconda" "\$HOME/anaconda" "/opt/conda" "/root/miniconda3" "/root/anaconda3" "\$HOME/.conda"; do [ -f "\$_d/etc/profile.d/conda.sh" ] && . "\$_d/etc/profile.d/conda.sh" && break; done');
    initParts.add('eval "\$(conda shell.bash hook 2>/dev/null)" 2>/dev/null || true');

    // 2. 激活环境 (优先激活指定环境，若未指定则激活 base)
    if (env.isNotEmpty) {
      initParts.add('conda activate $env');
    } else {
      initParts.add('conda activate base 2>/dev/null || true');
    }

    final execParts = <String>[];

    // 3. 切换工作目录 (从主目录出发)
    if (dir.isNotEmpty) {
      execParts.add('cd ${dir.contains(' ') ? '"$dir"' : dir}');
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
      execParts.add(cmd);
    }

    final initChain = '${initParts.join('; ')};';
    final execChain = execParts.join(' && ');

    return '$initChain $execChain'.trim();
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
