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

  /// Get the individual sequential command steps in order: 1. cd, 2. conda activate, 3. target command.
  List<String> toExecutableSteps({bool withMonRun = false}) {
    final steps = <String>[];
    final dir = workDir.trim();
    final env = condaEnv.trim();
    var cmd = command.trim();

    // 1. Switch working directory
    if (dir.isNotEmpty) {
      steps.add('cd ${dir.contains(' ') ? '"$dir"' : dir}');
    }

    // 2. Activate conda environment
    if (env.isNotEmpty) {
      steps.add('conda activate $env');
    }

    // 3. Target command code (split multiple lines into individual sequential steps)
    if (cmd.isNotEmpty) {
      if (withMonRun &&
          !cmd.startsWith('mon run') &&
          !cmd.startsWith('runmon run') &&
          !cmd.startsWith('mon wait')) {
        final taskName = name.trim().replaceAll('"', '');
        final nameArg = taskName.isNotEmpty ? '--name "$taskName" ' : '';
        cmd = 'mon run $nameArg-- $cmd';
      }
      for (final line in cmd.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          steps.add(trimmed);
        }
      }
    }

    return steps;
  }

  /// Compose multiline sequential executable script with self-contained terminal step-by-step trace execution.
  String toExecutableCommand({bool withMonRun = false}) {
    final steps = toExecutableSteps(withMonRun: withMonRun);
    final buffer = StringBuffer();

    buffer.writeln(r'''# 1. Search and source conda from common paths if conda command is not yet available
if ! type conda >/dev/null 2>&1; then
    for _d in "$CONDA_EXE" "$MAMBA_EXE" \
              "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniconda" "$HOME/anaconda" \
              "$HOME/miniforge3" "$HOME/mambaforge" "$HOME/.conda" \
              "/opt/conda" "/opt/miniconda3" "/opt/anaconda3" \
              "/usr/local/miniconda3" "/usr/local/anaconda3" \
              "/data/miniconda3" "/data/anaconda3" \
              /data/home/*/miniconda* /data/home/*/anaconda* \
              /home/*/miniconda* /home/*/anaconda* /home/*/miniforge* /home/*/mambaforge*; do
        if [ -n "$_d" ]; then
            if [ -f "$_d/etc/profile.d/conda.sh" ]; then
                . "$_d/etc/profile.d/conda.sh" 2>/dev/null
                break
            elif [ -f "$_d/bin/conda" ]; then
                export PATH="$_d/bin:$PATH"
                eval "$("$_d/bin/conda" shell.bash hook 2>/dev/null)" || true
                break
            fi
        fi
    done
fi

# 2. Extract and source conda initialize block from shell rc files if still needed
if ! type conda >/dev/null 2>&1; then
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        if [ -f "$rc" ]; then
            eval "$(sed -n '/# >>> conda initialize >>>/,/# <<< conda initialize <<</p' "$rc" 2>/dev/null)"
            if type conda >/dev/null 2>&1; then
                break
            fi
        fi
    done
fi

# 3. Inject Conda Shell Hook
if type conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook 2>/dev/null)" || true
fi

# 4. Load system and user environment profiles
[ -f /etc/profile ] && . /etc/profile 2>/dev/null
[ -f ~/.profile ] && . ~/.profile 2>/dev/null
[ -f "$HOME/.bash_profile" ] && . "$HOME/.bash_profile" 2>/dev/null
if [ -f "$HOME/.bashrc" ]; then
    eval "$(sed -e 's/\[ -z "\$PS1" \] && return//g' -e 's/case \$- in \*i\*\) ;; \*\) return;; esac//g' "$HOME/.bashrc" 2>/dev/null)" 2>/dev/null || true
fi

# 5. Interactive terminal prompt generator and step-by-step runner
_runmon_prompt() {
    local _env=""
    if [ -n "$CONDA_DEFAULT_ENV" ]; then
        _env="($CONDA_DEFAULT_ENV) "
    elif [ -n "$VIRTUAL_ENV" ]; then
        _env="($(basename "$VIRTUAL_ENV")) "
    fi
    local _u="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null || echo user)}"
    local _h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)"
    local _cwd="$PWD"
    local _disp_cwd="$_cwd"
    if [ -n "$HOME" ]; then
        if [ "$_cwd" = "$HOME" ]; then
            _disp_cwd="~"
        elif [[ "$_cwd" == "$HOME/"* ]]; then
            _disp_cwd="~${_cwd#$HOME}"
        fi
    fi
    local _sym="$"
    if [ "${EUID:-$(id -u 2>/dev/null)}" = "0" ]; then
        _sym="#"
    fi
    printf "\033[00m%s\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m%s " "$_env" "$_u" "$_h" "$_disp_cwd" "$_sym"
}

_runmon_step() {
    local _cmd="$1"
    [ -z "$_cmd" ] && return 0
    _runmon_prompt
    printf "%s\n" "$_cmd"
    eval "$_cmd"
    local _ret=$?
    if [ $_ret -ne 0 ]; then
        printf "\033[01;31m[RunMon] 步骤执行失败 (退出码: %d)\033[00m\n" "$_ret"
        _runmon_prompt
        printf "\n"
        exit $_ret
    fi
    return 0
}''');

    for (final step in steps) {
      final escaped = step.replaceAll("'", "'\\''");
      buffer.writeln("_runmon_step '$escaped'");
    }

    buffer.writeln('_runmon_prompt');
    buffer.writeln(r'printf "\n"');

    return buffer.toString().trim();
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
