import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmon_app/main.dart';
import 'package:runmon_app/state.dart';

Map<String, dynamic> _gpu(
  int index, {
  required int util,
  required int used,
  required List<Map<String, dynamic>> processes,
}) => {
  'index': index,
  'util': util,
  'mem_used': used,
  'mem_total': 24576,
  'temp': 42,
  'processes': processes,
};

AgentState _agent({
  required String id,
  required String name,
  required List<Map<String, dynamic>> gpus,
}) {
  return AgentState(
      ServerLink(
        relayUrl: 'https://example.test',
        appDeviceId: 'app',
        appToken: 'token',
        agentId: id,
        agentName: name,
        keyB64: '',
      ),
    )
    ..connected = true
    ..online = true
    ..hb = {'gpus': gpus, 'cpu': 35.6, 'mem': 81.9};
}

void _seedTwoServers() {
  appState.agents.clear();
  appState.agents['busy'] = _agent(
    id: 'busy',
    name: 'gpu-busy-server',
    gpus: [
      _gpu(
        0,
        util: 92,
        used: 22528,
        processes: [
          {'pid': 101, 'user': 'alice'},
          {'pid': 102, 'user': 'bob'},
        ],
      ),
      _gpu(
        1,
        util: 3,
        used: 1024,
        processes: [
          {'pid': 103, 'user': 'charlie'},
        ],
      ),
    ],
  );
  appState.agents['idle'] = _agent(
    id: 'idle',
    name: 'gpu-idle-server',
    gpus: [
      _gpu(0, util: 0, used: 0, processes: []),
      _gpu(1, util: 0, used: 0, processes: []),
    ],
  );
}

void main() {
  setUp(_seedTwoServers);
  tearDown(() => appState.agents.clear());

  testWidgets('主页拆分在线、监控任务和 GPU 占用状态', (tester) async {
    await tester.pumpWidget(const RunMonApp());

    expect(
      find.text('在线 · 无任务 · GPU 使用 · 3 进程', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('在线 · 无任务 · GPU 空闲 · 0 进程', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('在线'), findsNothing);
    expect(find.text('无监控任务'), findsNothing);
    expect(find.text('GPU 使用中（3 个进程）'), findsNothing);
    expect(find.text('暂无 GPU 进程'), findsNothing);
    expect(find.textContaining('在线 · 空闲'), findsNothing);
  });

  testWidgets('两张服务器卡的状态列和内容区域严格对齐', (tester) async {
    await tester.pumpWidget(const RunMonApp());

    final onlineBusy = tester.getRect(
      find.byKey(const ValueKey('server-connection-busy')),
    );
    final onlineIdle = tester.getRect(
      find.byKey(const ValueKey('server-connection-idle')),
    );
    final cardBusyRect = tester.getRect(
      find.byKey(const ValueKey('server-card-busy')),
    );
    final cardIdleRect = tester.getRect(
      find.byKey(const ValueKey('server-card-idle')),
    );
    expect(onlineBusy.right, onlineIdle.right);
    expect(
      onlineBusy.top - cardBusyRect.top,
      onlineIdle.top - cardIdleRect.top,
    );

    expect(cardBusyRect.size, cardIdleRect.size);

    final summaryBusy = tester.getRect(
      find.byKey(const ValueKey('server-summary-busy')),
    );
    final summaryIdle = tester.getRect(
      find.byKey(const ValueKey('server-summary-idle')),
    );
    expect(
      summaryBusy.left - cardBusyRect.left,
      summaryIdle.left - cardIdleRect.left,
    );
  });

  testWidgets('底部只保留靠左的 CPU 与内存摘要', (tester) async {
    await tester.pumpWidget(const RunMonApp());

    expect(find.text('CPU 35.6% · 内存 81.9%'), findsNWidgets(2));
    expect(find.textContaining('GPU 92%/3%'), findsNothing);
    expect(find.textContaining('GPU 0%/0%'), findsNothing);
  });

  testWidgets('任务数量变化时顶部状态仍保持右侧对齐', (tester) async {
    appState.agents['busy']!.runs = [
      {'id': 'run-1', 'status': 'running'},
      {'id': 'run-2', 'status': 'running'},
    ];

    await tester.pumpWidget(const RunMonApp());

    expect(
      find.text('在线 · 2 任务 · GPU 使用 · 3 进程', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('在线 · 无任务 · GPU 空闲 · 0 进程', findRichText: true),
      findsOneWidget,
    );

    final busy = tester.getRect(
      find.byKey(const ValueKey('server-connection-busy')),
    );
    final idle = tester.getRect(
      find.byKey(const ValueKey('server-connection-idle')),
    );
    final busyCard = tester.getRect(
      find.byKey(const ValueKey('server-card-busy')),
    );
    final idleCard = tester.getRect(
      find.byKey(const ValueKey('server-card-idle')),
    );
    expect(busy.right, idle.right);
    expect(busy.top - busyCard.top, idle.top - idleCard.top);
  });

  testWidgets('同一 PID 同时占用多张 GPU 时只统计一个进程', (tester) async {
    final gpus = appState.agents['busy']!.hb!['gpus'] as List;
    (gpus[1] as Map)['processes'] = [
      {'pid': 101, 'user': 'alice'},
    ];

    await tester.pumpWidget(const RunMonApp());

    expect(
      find.text('在线 · 无任务 · GPU 使用 · 2 进程', findRichText: true),
      findsOneWidget,
    );
  });

  for (final width in [320.0, 375.0, 414.0, 768.0]) {
    testWidgets('双服务器状态在 ${width.toInt()}px 宽度无溢出', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const RunMonApp());

      expect(tester.takeException(), isNull);
    });
  }
}
