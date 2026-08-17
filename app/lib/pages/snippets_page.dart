/// 命令信息块管理页面:添加、修改、删除预存命令配置。
library;

import 'package:flutter/material.dart';

import '../snippets.dart';
import '../ui.dart';

class SnippetsPage extends StatelessWidget {
  const SnippetsPage({super.key});

  void _showEditSheet(BuildContext context, [CommandSnippet? snippet]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Rm.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _SnippetEditSheet(snippet: snippet),
    );
  }

  void _confirmDelete(BuildContext context, CommandSnippet snippet) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除「${snippet.name}」?'),
        content: Text(
          '删除后该信息块将从命令库中移除。',
          style: sans(size: 13.5, color: Rm.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          SoftButton(
            label: '删除',
            icon: Icons.delete_outline_rounded,
            deep: Rm.coralDeep,
            tint: Rm.coralTint,
            onPressed: () {
              Navigator.pop(c);
              snippetStore.deleteSnippet(snippet.id);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('命令信息块库'),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 6, right: 6),
        child: PushButton(
          label: '新建信息块',
          icon: Icons.add_rounded,
          onPressed: () => _showEditSheet(context),
        ),
      ),
      body: ListenableBuilder(
        listenable: snippetStore,
        builder: (context, _) {
          final list = snippetStore.snippets;
          if (list.isEmpty) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: const BoxDecoration(
                          color: Rm.paper2,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.menu_book_rounded,
                          size: 28,
                          color: Rm.pearDeep,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '还没有保存的命令信息块',
                        style: sans(size: 16, weight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '保存常用的 Conda 环境、工作目录与运行命令，预约蹲卡或在终端中可一键载入开跑。',
                        textAlign: TextAlign.center,
                        style: sans(size: 13, color: Rm.inkSoft, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: list.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Rm.cyanTint,
                    borderRadius: BorderRadius.circular(Rm.radiusInput),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded,
                          size: 16, color: Rm.cyanDeep),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '预存常用的环境、目录与代码，在蹲卡预约和终端中可一键载入开跑。',
                          style: sans(size: 12.5, color: Rm.cyanDeep, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                );
              }
              final s = list[i - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: RmCard(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.name,
                              style: sans(
                                size: 15.5,
                                weight: FontWeight.w700,
                                spacing: -0.2,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: Rm.inkSoft,
                            ),
                            tooltip: '编辑',
                            onPressed: () => _showEditSheet(context, s),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: Rm.coralDeep,
                            ),
                            tooltip: '删除',
                            onPressed: () => _confirmDelete(context, s),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (s.condaEnv.trim().isNotEmpty)
                            _Tag(
                              icon: Icons.science_outlined,
                              label: 'conda: ${s.condaEnv.trim()}',
                              tint: Rm.cyanTint,
                              color: Rm.cyanDeep,
                            ),
                          if (s.workDir.trim().isNotEmpty)
                            _Tag(
                              icon: Icons.folder_outlined,
                              label: s.workDir.trim(),
                              tint: Rm.pearTint,
                              color: Rm.pearDeep,
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Rm.terminalBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          s.command.trim().isEmpty ? '(未设置命令)' : s.command,
                          style: mono(size: 12, color: Rm.terminalText),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  final Color color;
  const _Tag({
    required this.icon,
    required this.label,
    required this.tint,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(size: 11.5, weight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnippetEditSheet extends StatefulWidget {
  final CommandSnippet? snippet;
  const _SnippetEditSheet({this.snippet});

  @override
  State<_SnippetEditSheet> createState() => _SnippetEditSheetState();
}

class _SnippetEditSheetState extends State<_SnippetEditSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _envCtrl;
  late final TextEditingController _dirCtrl;
  late final TextEditingController _cmdCtrl;

  bool get _isEdit => widget.snippet != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.snippet?.name ?? '');
    _envCtrl = TextEditingController(text: widget.snippet?.condaEnv ?? '');
    _dirCtrl = TextEditingController(text: widget.snippet?.workDir ?? '');
    _cmdCtrl = TextEditingController(text: widget.snippet?.command ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _envCtrl.dispose();
    _dirCtrl.dispose();
    _cmdCtrl.dispose();
    super.dispose();
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: mono(size: 12.5, color: Rm.inkFaint),
        filled: true,
        fillColor: Rm.card,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Rm.radiusInput),
          borderSide: const BorderSide(color: Rm.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Rm.radiusInput),
          borderSide: const BorderSide(color: Rm.pearDeep, width: 1.4),
        ),
      );

  void _save() {
    final name = _nameCtrl.text.trim();
    final cmd = _cmdCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入信息块名称')),
      );
      return;
    }
    if (cmd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入命令行代码')),
      );
      return;
    }

    final id = widget.snippet?.id ??
        '${DateTime.now().millisecondsSinceEpoch}-${UniqueKey().hashCode}';
    final updated = CommandSnippet(
      id: id,
      name: name,
      condaEnv: _envCtrl.text.trim(),
      workDir: _dirCtrl.text.trim(),
      command: cmd,
    );

    if (_isEdit) {
      snippetStore.updateSnippet(updated);
    } else {
      snippetStore.addSnippet(updated);
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_isEdit ? '信息块已更新' : '信息块已创建')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _isEdit ? '编辑信息块' : '新建命令信息块',
                      style: sans(
                        size: 18,
                        weight: FontWeight.w700,
                        spacing: -0.3,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Rm.inkSoft),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const SectionLabel('信息块名称'),
                TextField(
                  controller: _nameCtrl,
                  style: sans(size: 14),
                  decoration: _inputDeco('例如: 训练 ResNet50'),
                ),
                const SizedBox(height: 12),
                const SectionLabel('Conda 环境名称 (可选)'),
                TextField(
                  controller: _envCtrl,
                  style: mono(size: 13, color: Rm.ink),
                  decoration: _inputDeco('例如: torch2 (留空则默认使用 base)'),
                ),
                const SizedBox(height: 12),
                const SectionLabel('工作目录文件夹 (可选)'),
                TextField(
                  controller: _dirCtrl,
                  style: mono(size: 13, color: Rm.ink),
                  decoration: _inputDeco('例如: ~/project/train (留空则在主目录)'),
                ),
                const SizedBox(height: 12),
                const SectionLabel('命令行代码'),
                TextField(
                  controller: _cmdCtrl,
                  style: mono(size: 13, color: Rm.ink),
                  maxLines: 2,
                  decoration: _inputDeco('例如: python train.py'),
                ),
                const SizedBox(height: 6),
                Text(
                  '执行时将自动从主目录启动，激活 Conda 环境并切换到工作目录。',
                  style: sans(size: 11.5, color: Rm.inkFaint, height: 1.4),
                ),
                const SizedBox(height: 20),
                Center(
                  child: PushButton(
                    label: _isEdit ? '保存修改' : '确认添加',
                    icon: Icons.check,
                    onPressed: _save,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
