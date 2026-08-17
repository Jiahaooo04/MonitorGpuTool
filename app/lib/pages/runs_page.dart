import 'package:flutter/material.dart';

import '../state.dart';
import '../swipe_delete.dart';
import '../ui.dart';
import 'gpu_process_sheet.dart';
import 'gpu_watch_sheet.dart';
import 'llm_settings_sheet.dart';
import 'run_detail_page.dart';
import '../terminal_gate.dart';

class RunsPage extends StatefulWidget {
  final String agentId;
  const RunsPage({super.key, required this.agentId});

  @override
  State<RunsPage> createState() => _RunsPageState();
}

class _RunsPageState extends State<RunsPage> {
  final _swipeCtrl = SwipeDeleteController();

  String get agentId => widget.agentId;

  Future<void> _stopRun(String runId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('停止任务「$name」?'),
        content: Text(
          '将向任务发送 Ctrl+C (SIGINT) 信号暂停/终止执行。',
          style: sans(size: 13.5, color: Rm.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          SoftButton(
            label: '停止运行',
            icon: Icons.stop_rounded,
            deep: Rm.coralDeep,
            tint: Rm.coralTint,
            onPressed: () => Navigator.pop(c, true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final r = await appState.sendCmd(agentId, 'stop', runId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r['ok'] == true
              ? '已停止「$name」'
              : '停止失败:${r['error'] ?? '未知错误'}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final agent = appState.agents[agentId];
        if (agent == null) return const Scaffold(body: SizedBox());
        final runningRuns = agent.runs
            .where((r) => (r['status'] as String?) == 'running')
            .toList();

        return Scaffold(
          appBar: AppBar(
            title: Text(agent.name),
            actions: [
              IconButton(
                tooltip: '蹲卡提醒',
                icon: const Icon(Icons.hourglass_top_rounded),
                onPressed:
                    agent.online &&
                        ((agent.hb?['gpus'] as List?)?.isNotEmpty ?? false)
                    ? () => showGpuWatchSheet(context, agentId)
                    : null,
              ),
              IconButton(
                tooltip: '报错总结',
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: agent.online
                    ? () => showLlmSettingsSheet(context, agentId, agent.name)
                    : null,
              ),
              IconButton(
                tooltip: '终端',
                icon: const Icon(Icons.terminal_rounded),
                onPressed: agent.online
                    ? () => openTerminalGuarded(context, agentId, agent.name)
                    : null,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _swipeCtrl.pagePointerDown(),
            child: Column(
              children: [
                if (agent.hb?['gpu_watch'] != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: GpuWatchBanner(agentId: agentId),
                  ),
                if (agent.hbHistory.length >= 2)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: _MetricsHistoryCard(agent: agent),
                  ),
                if (runningRuns.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: _ActiveRunsSection(
                      agent: agent,
                      runningRuns: runningRuns,
                      onStop: (id, name) => _stopRun(id, name),
                    ),
                  ),
                Expanded(child: _runList(agent)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _runList(AgentState agent) {
    return agent.runs.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '还没有任务',
                  style: sans(
                    size: 16,
                    weight: FontWeight.w600,
                    color: Rm.inkSoft,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '可点击右上角 ⏳ 蹲卡预约任务，或在 💻 终端中执行',
                  style: sans(
                    size: 12.5,
                    color: Rm.inkFaint,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Rm.terminalBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'python train.py',
                    style: mono(size: 12.5, color: Rm.terminalText),
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: agent.runs.length,
            itemBuilder: (context, i) {
              final r = agent.runs[i];
              final running = (r['status'] as String?) == 'running';
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SwipeDeleteRow(
                  rowKey: r['id'] as String,
                  controller: _swipeCtrl,
                  enabled: !running, // 运行中的任务不允许删,先停止
                  onDelete: () => _deleteRun(r['id'] as String),
                  child: _RunCard(
                    agentId: agentId,
                    run: r,
                    onStop: () =>
                        _stopRun(r['id'] as String, r['name'] as String? ?? '任务'),
                  ),
                ),
              );
            },
          );
  }

  Future<void> _deleteRun(String runId) async {
    final r = await appState.sendCmd(agentId, 'delete_run', runId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r['ok'] == true
              ? '已删除(服务器上的记录和日志一并清掉)'
              : '删除失败:${r['error'] ?? '未知错误'}',
        ),
      ),
    );
  }
}

/// 监控下方正在运行的任务控制块 (支持点击查看完整终端输出与一键 Ctrl+C 停止)
class _ActiveRunsSection extends StatelessWidget {
  final AgentState agent;
  final List<Map<String, dynamic>> runningRuns;
  final void Function(String runId, String name) onStop;
  const _ActiveRunsSection({
    required this.agent,
    required this.runningRuns,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return RmCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Rm.mint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '正在运行 (${runningRuns.length})',
                style: sans(
                  size: 13,
                  weight: FontWeight.w700,
                  color: Rm.mintDeep,
                ),
              ),
              const Spacer(),
              Text(
                '点击查看完整终端输出 →',
                style: sans(size: 11, color: Rm.inkFaint),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final run in runningRuns) ...[
            _ActiveRunItem(
              agentId: agent.link.agentId,
              agent: agent,
              run: run,
              onStop: () => onStop(
                run['id'] as String,
                run['name'] as String? ?? '任务',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActiveRunItem extends StatelessWidget {
  final String agentId;
  final AgentState agent;
  final Map<String, dynamic> run;
  final VoidCallback onStop;
  const _ActiveRunItem({
    required this.agentId,
    required this.agent,
    required this.run,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final runId = run['id'] as String;
    final tail = (agent.tails[runId] ?? '').trim();
    final lastLine = tail.isNotEmpty ? tail.split('\n').last.trim() : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RunDetailPage(agentId: agentId, runId: runId),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Rm.paper,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Rm.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      run['name'] as String? ?? '未命名任务',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(size: 14, weight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    fmtDuration(
                      (run['started_at'] as num?)?.toDouble(),
                      (run['ended_at'] as num?)?.toDouble(),
                      agent.serverNow(),
                    ),
                    style: mono(size: 11.5, color: Rm.inkSoft),
                  ),
                  const SizedBox(width: 8),
                  SoftButton(
                    label: '停止',
                    icon: Icons.stop_rounded,
                    deep: Rm.coralDeep,
                    tint: Rm.coralTint,
                    onPressed: onStop,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: Rm.terminalBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF232D38),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '日志',
                        style: mono(
                          size: 10.5,
                          weight: FontWeight.w600,
                          color: Rm.pear,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lastLine.isNotEmpty ? lastLine : '任务运行中 · 点击查看完整日志',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(size: 11.5, color: Rm.terminalText),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: Rm.inkFaint,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 资源历史曲线:CPU + 内存(人人都有)+ 每张 GPU(有 N 卡才显示)。
class _MetricsHistoryCard extends StatelessWidget {
  final AgentState agent;
  const _MetricsHistoryCard({required this.agent});

  Widget _metric(
    String label,
    Color color,
    List<double> values,
    String now, {
    VoidCallback? onTap,
  }) {
    final row = Row(
      children: [
        SizedBox(
          width: 52,
          child: onTap == null
              ? Text(label, style: mono(size: 11.5, color: Rm.inkFaint))
              : Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: mono(size: 11.5, color: Rm.inkFaint),
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 13,
                      color: Rm.inkFaint,
                    ),
                  ],
                ),
        ),
        Expanded(
          child: Sparkline(values: values, color: color, height: 34),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 44,
          child: Text(
            now,
            textAlign: TextAlign.right,
            style: mono(size: 12, weight: FontWeight.w600, color: Rm.ink),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: onTap == null
          ? row
          : Semantics(
              button: true,
              label: '查看 $label 占用进程',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                highlightColor: Rm.pearTint,
                splashColor: Rm.pearTint,
                onTap: onTap,
                child: row,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = agent.hbHistory;
    final gpus = (agent.hb?['gpus'] as List?) ?? [];
    final cpuNow = (agent.hb?['cpu'] as num?)?.round() ?? 0;
    final memNow = (agent.hb?['mem'] as num?)?.round() ?? 0;
    return RmCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '资源 · 最近 ${(h.length * 10 / 60).round()} 分钟',
            style: mono(size: 11, color: Rm.inkFaint),
          ),
          const SizedBox(height: 12),
          _metric('CPU', Rm.cyan, [
            for (final x in h) (x['cpu'] as num? ?? 0).toDouble(),
          ], '$cpuNow%'),
          _metric('内存', Rm.mint, [
            for (final x in h) (x['mem'] as num? ?? 0).toDouble(),
          ], '$memNow%'),
          for (final g in gpus)
            _metric(
              'GPU ${g['index']}',
              Rm.pear,
              [
                for (final x in h)
                  (((x['gpus'] as List?) ?? [])
                                  .cast<Map<String, dynamic>>()
                                  .where((y) => y['index'] == g['index'])
                                  .firstOrNull?['util']
                              as num? ??
                          0)
                      .toDouble(),
              ],
              '${g['util']}%',
              onTap: () {
                showGpuProcessSheet(
                  context,
                  Map<String, dynamic>.from(g as Map),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  final String agentId;
  final Map<String, dynamic> run;
  final VoidCallback? onStop;
  const _RunCard({
    required this.agentId,
    required this.run,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final status = run['status'] as String? ?? '?';
    final progress = run['progress'] as num?;
    final loss = run['last_loss'] as num?;
    final running = status == 'running';
    final meta = [
      if (loss != null) 'loss ${loss.toStringAsFixed(4)}',
      fmtDuration(
        (run['started_at'] as num?)?.toDouble(),
        (run['ended_at'] as num?)?.toDouble(),
        appState.agents[agentId]?.serverNow(),
      ),
    ].join('   ');
    return RmCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              RunDetailPage(agentId: agentId, runId: run['id'] as String),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  run['name'] as String? ?? '?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(size: 15, weight: FontWeight.w600, spacing: -0.2),
                ),
              ),
              const SizedBox(width: 12),
              StatusPill(status),
              if (running && onStop != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    size: 22,
                    color: Rm.coralDeep,
                  ),
                  tooltip: '停止运行 (Ctrl+C)',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onStop,
                ),
              ],
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: RmProgress(
                    value: progress / 100.0,
                    color: progressColor(status),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${progress.round()}%',
                  style: mono(size: 12, color: Rm.ink),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(meta, style: mono(size: 11.5, color: Rm.inkFaint)),
        ],
      ),
    );
  }
}
