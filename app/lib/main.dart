import 'package:flutter/material.dart';

import 'notifications.dart';
import 'pages/events_page.dart';
import 'pages/pair_page.dart';
import 'pages/settings_page.dart';
import 'pages/runs_page.dart';
import 'pages/snippets_page.dart';
import 'settings.dart';
import 'snippets.dart';
import 'state.dart';
import 'ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  appState.init();
  appSettings.load();
  snippetStore.load();
  initNotifications();
  runApp(const MonitorGpuToolApp());
}

class MonitorGpuToolApp extends StatelessWidget {
  const MonitorGpuToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MonitorGpuTool',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _shownNotice;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (appState.lastNotice != null &&
            appState.lastNotice != _shownNotice) {
          _shownNotice = appState.lastNotice;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_shownNotice!),
                  duration: const Duration(seconds: 5),
                ),
              );
            }
          });
        }
        final agents = appState.agents.values.toList();
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('MonitorGpuTool'),
                const SizedBox(width: 7),
                // 品牌记号:梨黄圆点
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: const BoxDecoration(
                    color: Rm.pear,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '命令库',
                icon: const Icon(Icons.menu_book_rounded),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SnippetsPage()),
                ),
              ),
              IconButton(
                tooltip: '事件',
                icon: const Icon(Icons.notifications_none_rounded),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EventsPage()),
                ),
              ),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          floatingActionButton: Padding(
            padding: const EdgeInsets.only(bottom: 6, right: 6),
            child: PushButton(
              label: '添加服务器',
              icon: Icons.add_link,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PairPage()),
              ),
            ),
          ),
          body: agents.isEmpty
              ? const _EmptyHome()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: agents.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _ServerCard(agent: agents[i]),
                  ),
                ),
        );
      },
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '让训练跑它的,\n你去过你的生活。',
                style: sans(
                  size: 26,
                  weight: FontWeight.w700,
                  spacing: -0.5,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '在服务器上装好 agent,任务状态、GPU、事件通知就会出现在这里。',
                style: sans(size: 14.5, color: Rm.inkSoft, height: 1.6),
              ),
              const SizedBox(height: 22),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Rm.terminalBg,
                  borderRadius: BorderRadius.circular(Rm.radiusCard),
                ),
                child: Text(
                  'pip install monitorgputool\nmon pair',
                  style: mono(size: 13, color: Rm.terminalText, height: 1.7),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                '然后点右下角「添加服务器」,扫码或粘贴配对载荷。',
                style: sans(size: 13.5, color: Rm.inkFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  final AgentState agent;
  const _ServerCard({required this.agent});

  @override
  Widget build(BuildContext context) {
    final hb = agent.hb;
    final gpus = ((hb?['gpus'] as List?) ?? const [])
        .whereType<Map>()
        .map((gpu) => Map<String, dynamic>.from(gpu))
        .toList();
    final running = agent.runs.where((r) => r['status'] == 'running').length;
    final processIds = <int>{};
    var processRows = 0;
    for (final gpu in gpus) {
      for (final process in (gpu['processes'] as List?) ?? const []) {
        if (process is! Map) continue;
        processRows++;
        final pid = process['pid'];
        if (pid is num) processIds.add(pid.toInt());
      }
    }
    final processCount = processIds.isNotEmpty
        ? processIds.length
        : processRows;
    final hasProcessData =
        gpus.isNotEmpty && gpus.every((gpu) => gpu.containsKey('processes'));
    final gpuInUse = gpus.any((gpu) {
      final util = (gpu['util'] as num?)?.toDouble() ?? 0;
      final memory = (gpu['mem_used'] as num?)?.toDouble() ?? 0;
      final processes = (gpu['processes'] as List?) ?? const [];
      return processes.isNotEmpty || util >= 10 || memory >= 512;
    });
    final gpuActivity = gpus.isEmpty
        ? '无 GPU'
        : gpuInUse
        ? processCount > 0
              ? 'GPU 使用 · $processCount 进程'
              : 'GPU 使用'
        : hasProcessData
        ? 'GPU 空闲 · 0 进程'
        : 'GPU 未知';
    final taskActivity = running > 0 ? '$running 任务' : '无任务';
    final (dotColor, connectionText, connectionColor) = !agent.connected
        ? (Rm.inkFaint, '连接中…', Rm.inkFaint)
        : agent.online
        ? (Rm.mint, '在线', Rm.mintDeep)
        : (Rm.coral, '服务器离线', Rm.coralDeep);
    return RmCard(
      key: ValueKey('server-card-${agent.link.agentId}'),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RunsPage(agentId: agent.link.agentId),
        ),
      ),
      onLongPress: () => _confirmDelete(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final statusWidth = (constraints.maxWidth * .66).clamp(
                150.0,
                330.0,
              );
              return Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      agent.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(
                        size: 16,
                        weight: FontWeight.w600,
                        spacing: -0.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    key: ValueKey('server-connection-${agent.link.agentId}'),
                    width: statusWidth,
                    height: 22,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text.rich(
                          TextSpan(
                            style: sans(
                              size: 11.5,
                              weight: FontWeight.w500,
                              color: Rm.inkFaint,
                            ),
                            children: agent.online
                                ? [
                                    TextSpan(
                                      text: connectionText,
                                      style: TextStyle(color: connectionColor),
                                    ),
                                    TextSpan(text: ' · $taskActivity · '),
                                    TextSpan(
                                      text: gpuActivity,
                                      style: TextStyle(
                                        color: gpuInUse
                                            ? Rm.pearDeep
                                            : Rm.inkFaint,
                                      ),
                                    ),
                                  ]
                                : [
                                    TextSpan(
                                      text: connectionText,
                                      style: TextStyle(color: connectionColor),
                                    ),
                                  ],
                          ),
                          maxLines: 1,
                          softWrap: false,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          if (gpus.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final g in gpus)
              MeterRow(
                label: 'GPU ${g['index']}',
                fraction: ((g['util'] as num?) ?? 0) / 100.0,
                value: '${g['util']}%',
                detail:
                    '${(((g['mem_used'] as num?) ?? 0) / 1024).toStringAsFixed(1)}'
                    '/'
                    '${(((g['mem_total'] as num?) ?? 0) / 1024).toStringAsFixed(1)}'
                    ' GB',
              ),
          ],
          if (hb != null) ...[
            SizedBox(height: gpus.isEmpty ? 14 : 4),
            Text(
              'CPU ${hb['cpu']}% · 内存 ${hb['mem']}%',
              key: ValueKey('server-summary-${agent.link.agentId}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(size: 11.5, color: Rm.inkFaint),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除「${agent.name}」?'),
        content: const Text('删除后需重新配对,服务器上的任务不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          SoftButton(
            label: '删除',
            icon: Icons.delete_outline,
            deep: Rm.coralDeep,
            tint: Rm.coralTint,
            onPressed: () => Navigator.pop(c, true),
          ),
        ],
      ),
    );
    if (ok == true) appState.removeServer(agent.link.agentId);
  }
}
