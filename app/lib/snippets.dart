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

  /// Get the individual sequential command steps (e.g. 1. conda activate, 2. cd, 3. python ...).
  List<String> toExecutableSteps({bool withMonRun = false}) {
    final steps = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. 激活环境 (优先激活指定环境，若未指定则激活 base)
    if (env.isNotEmpty) {
      steps.add('conda activate $env');
    } else {
      steps.add('conda activate base');
    }

    // 2. 切换工作目录
    if (dir.isNotEmpty) {
      steps.add('cd ${dir.contains(' ') ? '"$dir"' : dir}');
    }

    // 3. 执行目标命令代码
    if (cmd.isNotEmpty) {
      if (withMonRun &&
          !cmd.startsWith('mon run') &&
          !cmd.startsWith('runmon run') &&
          !cmd.startsWith('mon wait')) {
        final taskName = name.trim().replaceAll('"', '');
        final nameArg = taskName.isNotEmpty ? '--name "$taskName" ' : '';
        cmd = 'mon run $nameArg-- $cmd';
      }
      steps.add(cmd);
    }

    return steps;
  }

  /// Compose multiline sequential executable script with terminal step-by-step trace logging.
  String toExecutableCommand({bool withMonRun = false}) {
    final lines = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. 自动从 ~/.bashrc 提取 conda 初始化段并载入 (兼容任意服务器上的 PyPI runmon 守护进程)
    lines.add('eval "\$(sed -n \'/^# >>> conda initialize >>>/,/^# <<< conda initialize <<</p\' ~/.bashrc 2>/dev/null)" 2>/dev/null || true');
    lines.add('[ -z "\$CONDA_SHLVL" ] && for _d in "\$HOME/miniconda3" "\$HOME/anaconda3" "\$HOME/miniconda" "\$HOME/anaconda" "/opt/conda" "\$HOME/.conda" /data/home/*/miniconda* /data/home/*/anaconda*; do [ -f "\$_d/etc/profile.d/conda.sh" ] && . "\$_d/etc/profile.d/conda.sh" && break; done');
    lines.add('[ -z "\$CONDA_SHLVL" ] && eval "\$(conda shell.bash hook 2>/dev/null)" 2>/dev/null || true');

    // 2. 步骤 1: 打印并激活 Conda 环境
    if (env.isNotEmpty) {
      lines.add('echo "[RunMon] 🟢 [1/3] 激活 Conda 环境: $env"');
      lines.add('conda activate $env || source activate $env || true');
    } else {
      lines.add('echo "[RunMon] 🟢 [1/3] 激活 Conda 默认 base 环境"');
      lines.add('conda activate base 2>/dev/null || true');
    }

    // 3. 步骤 2: 打印并切换工作目录
    if (dir.isNotEmpty) {
      lines.add('echo "[RunMon] 📁 [2/3] 切换工作目录: $dir"');
      lines.add('cd ${dir.contains(' ') ? '"$dir"' : dir} || { echo "❌ [RunMon] 目录不存在: $dir"; exit 1; }');
    } else {
      lines.add('echo "[RunMon] 📁 [2/3] 当前工作目录: \$(pwd)"');
    }

    // 4. 步骤 3: 打印并执行目标命令代码
    if (cmd.isNotEmpty) {
      if (withMonRun &&
          !cmd.startsWith('mon run') &&
          !cmd.startsWith('runmon run') &&
          !cmd.startsWith('mon wait')) {
        final taskName = name.trim().replaceAll('"', '');
        final nameArg = taskName.isNotEmpty ? '--name "$taskName" ' : '';
        cmd = 'mon run $nameArg-- $cmd';
      }
      lines.add('echo "[RunMon] ▶️ [3/3] 执行命令: $cmd"');
      lines.add('echo "============================================================"');
      lines.add(cmd);
    }

    return lines.join('\n');
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
