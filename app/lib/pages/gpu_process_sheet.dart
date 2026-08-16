/// Hallmark · component: GPU process sheet · genre: playful
/// theme: Hum quiet register · states: occupied/idle/pressed
library;

import 'package:flutter/material.dart';

import '../ui.dart';

Future<void> showGpuProcessSheet(
  BuildContext context,
  Map<String, dynamic> gpu,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Rm.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => GpuProcessSheet(gpu: gpu),
  );
}

class GpuProcessSheet extends StatelessWidget {
  final Map<String, dynamic> gpu;

  const GpuProcessSheet({super.key, required this.gpu});

  static String _gb(Object? mb) =>
      (((mb as num?)?.toDouble() ?? 0) / 1024).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final index = (gpu['index'] as num?)?.toInt() ?? 0;
    final util = (gpu['util'] as num?)?.toDouble() ?? 0;
    final usedGb = _gb(gpu['mem_used']);
    final totalGb = _gb(gpu['mem_total']);
    final processes =
        ((gpu['processes'] as List?) ?? const [])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
          ..sort(
            (a, b) => ((b['gpu_mem_mb'] as num?) ?? 0).compareTo(
              (a['gpu_mem_mb'] as num?) ?? 0,
            ),
          );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Rm.hairline,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'GPU $index 占用进程',
                    style: sans(
                      size: 18,
                      weight: FontWeight.w700,
                      spacing: -0.3,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Rm.pearTint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${util.round()}%',
                    style: mono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: Rm.pearDeep,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '$usedGb / $totalGb GB 已用 · 数据约每 10 秒更新',
              style: mono(size: 11.5, color: Rm.inkFaint),
            ),
            const SizedBox(height: 16),
            if (processes.isEmpty)
              _EmptyGpu(index: index)
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: processes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) =>
                      _ProcessCard(process: processes[i], order: i + 1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyGpu extends StatelessWidget {
  final int index;

  const _EmptyGpu({required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      decoration: BoxDecoration(
        color: Rm.paper2,
        borderRadius: BorderRadius.circular(Rm.radiusInput),
        border: Border.all(color: Rm.hairline),
      ),
      child: Column(
        children: [
          const Icon(Icons.air_rounded, color: Rm.mintDeep, size: 25),
          const SizedBox(height: 8),
          Text(
            '当前没有检测到 GPU 进程',
            style: sans(size: 13.5, weight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'GPU $index 可能正空闲，或进程刚刚结束',
            style: sans(size: 11.5, color: Rm.inkFaint),
          ),
        ],
      ),
    );
  }
}

class _ProcessCard extends StatelessWidget {
  final Map<String, dynamic> process;
  final int order;

  const _ProcessCard({required this.process, required this.order});

  static String _gb(Object? mb) =>
      (((mb as num?)?.toDouble() ?? 0) / 1024).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final pid = (process['pid'] as num?)?.toInt() ?? 0;
    final name = (process['name'] as String?)?.trim();
    final user = (process['user'] as String?)?.trim();
    final cpu = ((process['cpu_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(
      1,
    );
    final memPct = ((process['mem_pct'] as num?)?.toDouble() ?? 0)
        .toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Rm.card,
        borderRadius: BorderRadius.circular(Rm.radiusInput),
        border: Border.all(color: Rm.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Rm.pearTint,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$order',
                  style: mono(
                    size: 11,
                    weight: FontWeight.w600,
                    color: Rm.pearDeep,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${name?.isNotEmpty == true ? name : '未知进程'} · PID $pid',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(size: 13.5, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.person_outline_rounded,
                size: 16,
                color: Rm.inkFaint,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  user?.isNotEmpty == true ? user! : '未知用户',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(size: 11.5, color: Rm.inkSoft),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _MetricChip(label: 'CPU $cpu%'),
              _MetricChip(
                label: '内存 ${_gb(process['mem_used_mb'])} GB · $memPct%',
              ),
              _MetricChip(
                label: '显存 ${_gb(process['gpu_mem_mb'])} GB',
                emphasized: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final bool emphasized;

  const _MetricChip({required this.label, this.emphasized = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: emphasized ? Rm.pearTint : Rm.paper2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: mono(
          size: 10.5,
          weight: FontWeight.w500,
          color: emphasized ? Rm.pearDeep : Rm.inkSoft,
        ),
      ),
    );
  }
}
