import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmon_app/pages/runs_page.dart';
import 'package:runmon_app/state.dart';
import 'package:runmon_app/ui.dart';

Map<String, dynamic> _gpu(
  int index, {
  required int util,
  required int used,
  List<Map<String, dynamic>> processes = const [],
}) => {
  'index': index,
  'util': util,
  'mem_used': used,
  'mem_total': 24576,
  'temp': index == 0 ? 71 : 42,
  'processes': processes,
};

AgentState _agent() {
  final gpu0 = _gpu(
    0,
    util: 92,
    used: 22528,
    processes: [
      {
        'pid': 27182,
        'user': 'alice',
        'name': 'python',
        'cpu_pct': 132.0,
        'mem_used_mb': 7270,
        'mem_pct': 5.7,
        'gpu_mem_mb': 18432,
      },
      {
        'pid': 28104,
        'user': 'bob',
        'name': 'torchrun',
        'cpu_pct': 18.4,
        'mem_used_mb': 2048,
        'mem_pct': 1.6,
        'gpu_mem_mb': 4096,
      },
    ],
  );
  final gpu1 = _gpu(1, util: 3, used: 1024);
  final agent =
      AgentState(
          ServerLink(
            relayUrl: 'https://example.test',
            appDeviceId: 'app',
            appToken: 'token',
            agentId: 'dual-gpu',
            agentName: 'dual-gpu',
            keyB64: '',
          ),
        )
        ..connected = true
        ..online = true
        ..hb = {
          'gpus': [gpu0, gpu1],
          'cpu': 35,
          'mem': 82,
        };
  agent.hbHistory
    ..add({
      'gpus': [gpu0, gpu1],
      'cpu': 34,
      'mem': 81,
    })
    ..add(agent.hb!);
  return agent;
}

Future<void> _pumpRunsPage(WidgetTester tester) async {
  appState.agents.clear();
  final agent = _agent();
  appState.agents[agent.link.agentId] = agent;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: const RunsPage(agentId: 'dual-gpu'),
    ),
  );
}

void main() {
  tearDown(() => appState.agents.clear());

  testWidgets('点击 GPU 行显示全部占用进程与资源摘要', (tester) async {
    await _pumpRunsPage(tester);

    await tester.tap(find.text('GPU 0'));
    await tester.pumpAndSettle();

    expect(find.text('GPU 0 占用进程'), findsOneWidget);
    expect(find.text('python · PID 27182'), findsOneWidget);
    expect(find.text('torchrun · PID 28104'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('CPU 132.0%'), findsOneWidget);
    expect(find.text('内存 7.1 GB · 5.7%'), findsOneWidget);
    expect(find.text('显存 18.0 GB'), findsOneWidget);
  });

  testWidgets('点击空闲 GPU 显示没有进程', (tester) async {
    await _pumpRunsPage(tester);

    await tester.tap(find.text('GPU 1'));
    await tester.pumpAndSettle();

    expect(find.text('GPU 1 占用进程'), findsOneWidget);
    expect(find.text('当前没有检测到 GPU 进程'), findsOneWidget);
  });

  testWidgets('窄屏打开多进程弹窗不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpRunsPage(tester);
    await tester.tap(find.text('GPU 0'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
