/// 远程交互终端页面:提供虚拟控制键、软键盘输入缓冲及命令库载入。
library;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../settings.dart';
import '../snippets.dart';
import '../state.dart';
import '../ui.dart';
import 'snippets_page.dart';

class TerminalPage extends StatefulWidget {
  final String agentId;
  final String agentName;
  final String? cwd;
  final String? presetCommand;
  const TerminalPage({
    super.key,
    required this.agentId,
    required this.agentName,
    this.cwd,
    this.presetCommand,
  });

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final terminal = Terminal(maxLines: 5000);
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    terminal.onOutput = (data) => appState.termInput(widget.agentId, data);
    terminal.onResize =
        (w, h, pw, ph) => appState.termResize(widget.agentId, h, w);
    appState.openTerminal(widget.agentId, terminal.write,
        rows: terminal.viewHeight, cols: terminal.viewWidth, cwd: widget.cwd);
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _inputFocus.dispose();
    appState.closeTerminal(widget.agentId);
    super.dispose();
  }

  void _sendKey(String keyData) {
    appState.termInput(widget.agentId, keyData);
  }

  void _sendInputText() {
    final text = _inputCtrl.text;
    if (text.isNotEmpty) {
      appState.termInput(widget.agentId, '$text\r');
      _inputCtrl.clear();
    }
  }

  void _showSnippetPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Rm.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => _TerminalSnippetSheet(
        onFill: (snippet) {
          Navigator.pop(ctx);
          final text = snippet.toExecutableSteps().join(' && ');
          appState.termInput(widget.agentId, text);
        },
        onRun: (snippet) {
          Navigator.pop(ctx);
          final steps = snippet.toExecutableSteps();
          for (final step in steps) {
            appState.termInput(widget.agentId, '$step\r');
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Rm.terminalBg,
      appBar: AppBar(
        backgroundColor: Rm.terminalBg,
        title: Text(
          '${widget.agentName} · 终端',
          style:
              sans(size: 16, weight: FontWeight.w600, color: Rm.terminalText),
        ),
        iconTheme: const IconThemeData(color: Rm.terminalText, size: 20),
        actions: [
          IconButton(
            tooltip: '命令库',
            icon: const Icon(Icons.menu_book_rounded, color: Rm.pear),
            onPressed: _showSnippetPicker,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, child) {
            final agent = appState.agents[widget.agentId];
            final offline = agent == null || !agent.online;
            return Column(
              children: [
                if (offline)
                  Container(
                    width: double.infinity,
                    color: Rm.coralDeep,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    child: Text(
                      '服务器已断开 · 返回上一页重新进入以恢复终端',
                      style: sans(size: 12.5, color: Rm.paper),
                    ),
                  ),
                if (widget.presetCommand != null)
                  _PresetBar(
                    command: widget.presetCommand!,
                    onFill: () => appState.termInput(
                        widget.agentId, widget.presetCommand!),
                  ),
                Expanded(child: child!),
                _buildAccessoryBar(),
                _buildQuickInputBar(),
              ],
            );
          },
          child: TerminalView(
            terminal,
            textStyle: TerminalStyle(
              fontSize: appSettings.terminalFontSize,
              fontFamily: Rm.mono,
            ),
            theme: TerminalThemes.defaultTheme,
            autofocus: true,
          ),
        ),
      ),
    );
  }

  /// 终端底部辅助按键栏: 退格、Ctrl+C、Tab、Esc、上下键、命令库
  Widget _buildAccessoryBar() {
    return Container(
      color: const Color(0xFF1B222A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _KeyButton(label: '⌫ 退格', onTap: () => _sendKey('\x7f')),
            const SizedBox(width: 6),
            _KeyButton(
              label: 'Ctrl+C',
              color: Rm.coral,
              onTap: () => _sendKey('\x03'),
            ),
            const SizedBox(width: 6),
            _KeyButton(label: 'Tab', onTap: () => _sendKey('\t')),
            const SizedBox(width: 6),
            _KeyButton(label: 'Esc', onTap: () => _sendKey('\x1b')),
            const SizedBox(width: 6),
            _KeyButton(label: '▲ 上', onTap: () => _sendKey('\x1b[A')),
            const SizedBox(width: 6),
            _KeyButton(label: '▼ 下', onTap: () => _sendKey('\x1b[B')),
            const SizedBox(width: 6),
            _KeyButton(label: '⏎ 回车', onTap: () => _sendKey('\r')),
            const SizedBox(width: 6),
            _KeyButton(
              label: '⌨ 收起',
              color: Rm.inkFaint,
              onTap: () => FocusScope.of(context).unfocus(),
            ),
            const SizedBox(width: 8),
            _KeyButton(
              label: '📚 命令库',
              color: Rm.pear,
              onTap: _showSnippetPicker,
            ),
          ],
        ),
      ),
    );
  }

  /// 终端底部快捷输入框 (支持完整中文输入法、光标移动及退格删除，点击发送直接送入终端)
  Widget _buildQuickInputBar() {
    return Container(
      color: const Color(0xFF13181E),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF1E262E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2C3642)),
              ),
              child: TextField(
                controller: _inputCtrl,
                focusNode: _inputFocus,
                style: mono(size: 12.5, color: Rm.terminalText),
                decoration: InputDecoration(
                  hintText: '输入命令直接发送...',
                  hintStyle: mono(size: 12, color: const Color(0xFF677380)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _sendInputText(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendInputText,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Rm.pearDeep,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                '发送',
                style: sans(
                  size: 12.5,
                  weight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? color;
  const _KeyButton({
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF26303B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF374454)),
        ),
        child: Text(
          label,
          style: mono(
            size: 11.5,
            weight: FontWeight.w600,
            color: color ?? Rm.terminalText,
          ),
        ),
      ),
    );
  }
}

class _PresetBar extends StatelessWidget {
  final String command;
  final VoidCallback onFill;
  const _PresetBar({required this.command, required this.onFill});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E262E),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              command,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(size: 12, color: Rm.terminalText),
            ),
          ),
          TextButton(
            onPressed: onFill,
            style: TextButton.styleFrom(
              foregroundColor: Rm.pear,
              textStyle: sans(size: 13, weight: FontWeight.w600),
            ),
            child: const Text('填入命令'),
          ),
        ],
      ),
    );
  }
}

/// 终端中从命令库选择信息块弹层
class _TerminalSnippetSheet extends StatelessWidget {
  final void Function(CommandSnippet snippet) onFill;
  final void Function(CommandSnippet snippet) onRun;
  const _TerminalSnippetSheet({
    required this.onFill,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: snippetStore,
      builder: (context, _) {
        final snippets = snippetStore.snippets;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '从命令库载入',
                      style: sans(
                        size: 17,
                        weight: FontWeight.w700,
                        spacing: -0.3,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: const Text('管理'),
                      style: TextButton.styleFrom(
                        foregroundColor: Rm.inkSoft,
                        textStyle: sans(size: 12.5),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const SnippetsPage()),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (snippets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '命令库为空，可点击右上角「管理」添加信息块',
                        style: sans(size: 13, color: Rm.inkSoft),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: snippets.length,
                      itemBuilder: (context, i) {
                        final s = snippets[i];
                        final previewCmd = s.toExecutableSteps().join(' && ');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: RmCard(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        s.name,
                                        style: sans(
                                          size: 14.5,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    SoftButton(
                                      label: '填入',
                                      icon: Icons.input_rounded,
                                      deep: Rm.ink,
                                      tint: Rm.paper2,
                                      onPressed: () => onFill(s),
                                    ),
                                    const SizedBox(width: 8),
                                    SoftButton(
                                      label: '执行',
                                      icon: Icons.play_arrow_rounded,
                                      deep: Rm.mintDeep,
                                      tint: Rm.mintTint,
                                      onPressed: () => onRun(s),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Rm.terminalBg,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    previewCmd,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(
                                        size: 11, color: Rm.terminalText),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
