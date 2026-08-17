/// 蹲卡提醒配置弹层:勾选要蹲的 GPU、每张卡设空闲门槛，从存储库选择预约执行信息块。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../snippets.dart';
import '../state.dart';
import '../ui.dart';
import 'snippets_page.dart';

/// 每张卡的本地编辑状态。
class _CardCfg {
  bool selected = false;
  bool wholeCard = true; // true=整卡空闲;false=空闲显存 ≥ freeGb
  double freeGb;
  _CardCfg({this.freeGb = 10});
}

Future<void> showGpuWatchSheet(BuildContext context, String agentId) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Rm.paper,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _GpuWatchSheet(agentId: agentId),
  );
}

class _GpuWatchSheet extends StatefulWidget {
  final String agentId;
  const _GpuWatchSheet({required this.agentId});

  @override
  State<_GpuWatchSheet> createState() => _GpuWatchSheetState();
}

class _GpuWatchSheetState extends State<_GpuWatchSheet> {
  final Map<int, _CardCfg> _cfg = {};
  double _hold = 5;
  late final TextEditingController _holdCtrl;
  String? _selectedSnippetId;
  bool _sending = false;
  bool _hasWatch = false;

  AgentState? get _agent => appState.agents[widget.agentId];
  List<Map<String, dynamic>> get _gpus =>
      ((_agent?.hb?['gpus'] as List?) ?? []).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    final watch = _agent?.hb?['gpu_watch'] as Map<String, dynamic>?;
    _hasWatch = watch != null;
    final cards = (watch?['cards'] as Map<String, dynamic>?) ?? {};
    for (final g in _gpus) {
      final idx = (g['index'] as num).toInt();
      final totalGb = ((g['mem_total'] as num?) ?? 0) / 1024;
      final c = _CardCfg(freeGb: (totalGb / 2).clamp(1, 999).roundToDouble());
      if (cards.containsKey('$idx')) {
        c.selected = true;
        final need = cards['$idx'];
        if (need != null) {
          c.wholeCard = false;
          c.freeGb = (need as num).toDouble();
        }
      }
      _cfg[idx] = c;
    }
    if (watch != null) {
      _hold = ((watch['hold_minutes'] as num?) ?? 5).toDouble();
      final cmd = watch['command'] as String? ?? '';
      // 尝试匹配已有的 snippet
      final match = snippetStore.snippets.where((s) => s.toExecutableCommand() == cmd).firstOrNull;
      if (match != null) {
        _selectedSnippetId = match.id;
      }
    }
    _holdCtrl = TextEditingController(text: '${_hold.round()}');
  }

  @override
  void dispose() {
    _holdCtrl.dispose();
    super.dispose();
  }

  void _onHoldChipSelected(double minutes) {
    setState(() {
      _hold = minutes;
      _holdCtrl.text = '${minutes.round()}';
    });
  }

  void _onHoldInputChanged(String text) {
    if (text.trim().isEmpty) return;
    final val = int.tryParse(text.trim());
    if (val != null) {
      final clamped = val.clamp(0, 120);
      setState(() {
        _hold = clamped.toDouble();
      });
    }
  }

  Future<void> _submit() async {
    final cards = <String, dynamic>{};
    _cfg.forEach((idx, c) {
      if (c.selected) cards['$idx'] = c.wholeCard ? null : c.freeGb;
    });
    if (cards.isEmpty) {
      _toast('先勾选至少一张卡');
      return;
    }

    final snippet = _selectedSnippetId != null ? snippetStore.getById(_selectedSnippetId!) : null;
    final command = snippet?.toExecutableCommand() ?? '';
    final name = snippet?.name ?? '';

    setState(() => _sending = true);
    final r = await appState.sendCmd(widget.agentId, 'gpu_watch_set', '', {
      'cards': cards,
      'hold_minutes': _hold,
      'command': command,
      'name': name,
    });
    if (!mounted) return;
    setState(() => _sending = false);
    if (r['ok'] == true) {
      final msg = command.isEmpty
          ? '蹲卡已开启,等到就通知你 🎉'
          : '蹲卡 + 预约已开启,等到自动开跑 🚀';
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      messenger?.showSnackBar(SnackBar(content: Text(msg)));
    } else {
      _toast('开启失败:${r['error'] ?? '未知错误'}');
    }
  }

  Future<void> _cancel() async {
    setState(() => _sending = true);
    final r =
        await appState.sendCmd(widget.agentId, 'gpu_watch_cancel', '', {});
    if (!mounted) return;
    setState(() => _sending = false);
    if (r['ok'] == true) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      messenger?.showSnackBar(const SnackBar(content: Text('已取消蹲卡')));
    } else {
      _toast('取消失败:${r['error'] ?? '未知错误'}');
    }
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _holdChip(double minutes, String label) {
    final on = _hold == minutes;
    return ChoiceChip(
      label: Text(label),
      selected: on,
      onSelected: (_) => _onHoldChipSelected(minutes),
      labelStyle: sans(
          size: 12.5,
          weight: FontWeight.w600,
          color: on ? Rm.pearDeep : Rm.inkSoft),
      selectedColor: Rm.pearTint,
      backgroundColor: Rm.card,
      side: BorderSide(color: on ? Rm.pearDeep : Rm.hairline),
      showCheckmark: false,
      shape: const StadiumBorder(),
    );
  }

  Widget _gpuRow(Map<String, dynamic> g) {
    final idx = (g['index'] as num).toInt();
    final c = _cfg[idx]!;
    final totalMb = ((g['mem_total'] as num?) ?? 0).toDouble();
    final freeMb = totalMb - ((g['mem_used'] as num?) ?? 0).toDouble();
    final totalGb = totalMb / 1024;
    return RmCard(
      padding: const EdgeInsets.fromLTRB(6, 2, 14, 2),
      onTap: () => setState(() => c.selected = !c.selected),
      child: Column(children: [
        Row(children: [
          Checkbox(
            value: c.selected,
            activeColor: Rm.pearDeep,
            onChanged: (v) => setState(() => c.selected = v ?? false),
          ),
          Text('GPU $idx',
              style: sans(size: 14, weight: FontWeight.w700, spacing: -0.2)),
          const SizedBox(width: 10),
          Text('${g['util']}%',
              style: mono(size: 11.5, color: Rm.inkFaint)),
          const Spacer(),
          Text(
              '空闲 ${(freeMb / 1024).toStringAsFixed(0)} / '
              '${totalGb.toStringAsFixed(0)}GB',
              style: mono(size: 11.5, color: Rm.inkSoft)),
        ]),
        if (c.selected)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 0, 10),
            child: Row(children: [
              _modeChip(c, true, '整卡空闲'),
              const SizedBox(width: 8),
              _modeChip(c, false, '空闲 ≥ ${c.freeGb.round()}GB'),
              if (!c.wholeCard)
                Expanded(
                  child: Slider(
                    value: c.freeGb.clamp(1, totalGb.floorToDouble()),
                    min: 1,
                    max: totalGb.floorToDouble().clamp(1, 9999),
                    divisions: totalGb.floor() > 1 ? totalGb.floor() - 1 : 1,
                    activeColor: Rm.pearDeep,
                    inactiveColor: Rm.paper3,
                    onChanged: (v) =>
                        setState(() => c.freeGb = v.roundToDouble()),
                  ),
                )
              else
                const Spacer(),
            ]),
          ),
      ]),
    );
  }

  Widget _modeChip(_CardCfg c, bool whole, String label) {
    final on = c.wholeCard == whole;
    return GestureDetector(
      onTap: () => setState(() => c.wholeCard = whole),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: on ? Rm.pearTint : Rm.paper2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? Rm.pearDeep : Rm.hairline),
        ),
        child: Text(label,
            style: sans(
                size: 12,
                weight: FontWeight.w600,
                color: on ? Rm.pearDeep : Rm.inkSoft)),
      ),
    );
  }

  Widget _snippetSelector() {
    return ListenableBuilder(
      listenable: snippetStore,
      builder: (context, _) {
        final snippets = snippetStore.snippets;
        final selected = _selectedSnippetId != null
            ? snippetStore.getById(_selectedSnippetId!)
            : null;

        if (snippets.isEmpty) {
          return RmCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 18, color: Rm.inkFaint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '命令库暂无预存信息块',
                        style: sans(size: 13.5, color: Rm.inkSoft),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SoftButton(
                  label: '前往命令库添加',
                  icon: Icons.add_rounded,
                  deep: Rm.pearDeep,
                  tint: Rm.pearTint,
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SnippetsPage()),
                    );
                  },
                ),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: Rm.card,
                borderRadius: BorderRadius.circular(Rm.radiusInput),
                border: Border.all(color: Rm.hairline),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _selectedSnippetId,
                  isExpanded: true,
                  icon: const Icon(Icons.arrow_drop_down_rounded,
                      color: Rm.inkSoft),
                  hint: Text(
                    '仅蹲卡通知 (不自动执行命令)',
                    style: sans(size: 13.5, color: Rm.inkFaint),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(
                        '仅蹲卡通知 (不自动执行命令)',
                        style: sans(size: 13.5, color: Rm.inkSoft),
                      ),
                    ),
                    for (final s in snippets)
                      DropdownMenuItem<String?>(
                        value: s.id,
                        child: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(
                            size: 13.5,
                            weight: FontWeight.w600,
                            color: Rm.ink,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() => _selectedSnippetId = id),
                ),
              ),
            ),
            if (selected != null) ...[
              const SizedBox(height: 10),
              RmCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          selected.name,
                          style: sans(size: 14, weight: FontWeight.w700),
                        ),
                        const Spacer(),
                        if (selected.condaEnv.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Rm.cyanTint,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'conda: ${selected.condaEnv}',
                              style: mono(size: 10.5, color: Rm.cyanDeep),
                            ),
                          ),
                      ],
                    ),
                    if (selected.workDir.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.folder_outlined,
                              size: 12, color: Rm.inkFaint),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              selected.workDir,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono(size: 11, color: Rm.inkSoft),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Rm.terminalBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        selected.command,
                        style: mono(size: 11.5, color: Rm.terminalText),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SnippetsPage()),
                    );
                  },
                  child: Text(
                    '管理命令库 →',
                    style: sans(
                      size: 12,
                      weight: FontWeight.w600,
                      color: Rm.pearDeep,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('蹲卡提醒与预约',
                        style: sans(
                            size: 18, weight: FontWeight.w700, spacing: -0.3)),
                    const Spacer(),
                    if (_hasWatch)
                      SoftButton(
                          label: '取消蹲卡',
                          icon: Icons.close_rounded,
                          deep: Rm.coralDeep,
                          tint: Rm.coralTint,
                          onPressed: _sending ? null : _cancel),
                  ],
                ),
                const SizedBox(height: 6),
                Text('勾选的卡全部空出来时，手机马上收到通知；若选好命令信息块，到点将自动开跑。',
                    style: sans(size: 12.5, color: Rm.inkSoft, height: 1.5)),
                const SizedBox(height: 16),
                const SectionLabel('选择要蹲的卡'),
                for (final g in _gpus)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _gpuRow(g)),
                const SizedBox(height: 10),
                const SectionLabel('需持续满足(防假空闲)'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _holdChip(0, '立即'),
                    _holdChip(5, '5 分钟'),
                    _holdChip(10, '10 分钟'),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 68,
                          height: 34,
                          alignment: Alignment.center,
                          child: TextField(
                            controller: _holdCtrl,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => FocusScope.of(context).unfocus(),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(3),
                            ],
                            style: mono(
                                size: 13,
                                weight: FontWeight.w600,
                                color: Rm.ink),
                            textAlign: TextAlign.center,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 6),
                              filled: true,
                              fillColor: Rm.card,
                              enabledBorder: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(Rm.radiusInput),
                                borderSide:
                                    const BorderSide(color: Rm.hairline),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(Rm.radiusInput),
                                borderSide: const BorderSide(
                                    color: Rm.pearDeep, width: 1.4),
                              ),
                            ),
                            onChanged: _onHoldInputChanged,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('分钟 (0-120)',
                            style: sans(size: 12.5, color: Rm.inkSoft)),
                      ],
                    ),
                  ],
                ),
              const SizedBox(height: 18),
              const SectionLabel('预约执行信息块 (从命令库选取)'),
              _snippetSelector(),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Rm.cyanTint,
                  borderRadius: BorderRadius.circular(Rm.radiusInput),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 15, color: Rm.cyanDeep),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '自动激活 Conda、进入工作目录并设置 CUDA_VISIBLE_DEVICES 启动任务。',
                        style: sans(size: 11.5, color: Rm.cyanDeep, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: PushButton(
                  label: _hasWatch ? '更新蹲卡' : '开始蹲卡',
                  icon: Icons.hourglass_top_rounded,
                  onPressed: _sending ? null : _submit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 服务器页顶部的"蹲卡中"横幅:实时达标状态 + 点击进入编辑。
class GpuWatchBanner extends StatelessWidget {
  final String agentId;
  const GpuWatchBanner({super.key, required this.agentId});

  @override
  Widget build(BuildContext context) {
    final agent = appState.agents[agentId];
    final watch = agent?.hb?['gpu_watch'] as Map<String, dynamic>?;
    if (agent == null || watch == null || watch['fired'] == true) {
      return const SizedBox.shrink();
    }
    final cards = (watch['cards'] as Map<String, dynamic>?) ?? {};
    final states =
        ((watch['card_states'] as List?) ?? []).cast<Map<String, dynamic>>();
    final okCount = states.where((s) => s['ok'] == true).length;
    final holdMin = ((watch['hold_minutes'] as num?) ?? 5).toDouble();
    final since = (watch['since'] as num?)?.toDouble();
    final desc = cards.entries
        .map((e) =>
            '卡${e.key}${e.value == null ? ' 整卡' : ' ≥${(e.value as num).round()}GB'}')
        .join(' · ');
    String status;
    if (watch['ok'] == true && since != null) {
      final held = (agent.serverNow() - since).clamp(0, double.infinity);
      status = holdMin > 0
          ? '全部达标,持续 ${fmtDuration(0, held.toDouble())} / ${holdMin.round()} 分钟'
          : '全部达标,即将触发';
    } else {
      status = '$okCount/${states.length} 张达标,等待中';
    }
    final name = watch['name'] as String? ?? '';
    final command = watch['command'] as String? ?? '';
    final taskLabel = name.isNotEmpty ? name : command;
    return RmCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      onTap: () => showGpuWatchSheet(context, agentId),
      child: Row(children: [
        const Icon(Icons.hourglass_top_rounded, size: 18, color: Rm.pearDeep),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('蹲卡中 · $desc',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(size: 13, weight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(taskLabel.isEmpty ? status : '$status · 预约: $taskLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(size: 11, color: Rm.inkSoft)),
          ]),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.chevron_right_rounded, size: 18, color: Rm.inkFaint),
      ]),
    );
  }
}
