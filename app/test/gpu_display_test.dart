import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monitorgputool_app/main.dart';
import 'package:monitorgputool_app/state.dart';
import 'package:monitorgputool_app/ui.dart';

void main() {
  setUp(() {
    appState.agents.clear();
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
            'gpus': [
              {'index': 0, 'util': 92, 'mem_used': 22528, 'mem_total': 24576},
              {'index': 1, 'util': 3, 'mem_used': 1024, 'mem_total': 24576},
            ],
            'cpu': 35,
            'mem': 82,
          };
    appState.agents[agent.link.agentId] = agent;
  });

  tearDown(() => appState.agents.clear());

  testWidgets('GPU 显存以 GB 显示', (tester) async {
    await tester.pumpWidget(const MonitorGpuToolApp());

    expect(find.text('92%'), findsOneWidget);
    expect(find.text('3%'), findsOneWidget);
    expect(find.text('22.0/24.0 GB'), findsOneWidget);
    expect(find.text('1.0/24.0 GB'), findsOneWidget);
  });

  testWidgets('GPU 百分号、分隔点和显存数值分别对齐', (tester) async {
    await tester.pumpWidget(const MonitorGpuToolApp());

    final percent0 = tester.getRect(find.text('92%'));
    final percent1 = tester.getRect(find.text('3%'));
    expect(percent0.right, percent1.right);

    final dots = find
        .descendant(of: find.byType(MeterRow), matching: find.text('·'))
        .evaluate()
        .toList();
    expect(dots, hasLength(2));
    final dotCenters = dots
        .map(
          (element) => tester.getRect(find.byWidget(element.widget)).center.dx,
        )
        .toList();
    expect(dotCenters[0], dotCenters[1]);

    final memory0 = tester.getRect(find.text('22.0/24.0 GB'));
    final memory1 = tester.getRect(find.text('1.0/24.0 GB'));
    expect(memory0.right, memory1.right);
  });

  testWidgets('不同数值长度不会改变 GPU 进度条宽度', (tester) async {
    await tester.pumpWidget(const MonitorGpuToolApp());

    final bars = tester
        .widgetList<RmProgress>(find.byType(RmProgress))
        .toList();
    expect(bars, hasLength(2));
    final widths = find
        .byType(RmProgress)
        .evaluate()
        .map((element) => tester.getSize(find.byWidget(element.widget)).width)
        .toList();
    expect(widths[0], widths[1]);
  });

  for (final width in [320.0, 375.0, 414.0, 768.0]) {
    testWidgets('GPU 横条在 ${width.toInt()}px 宽度无溢出', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MonitorGpuToolApp());

      expect(tester.takeException(), isNull);
    });
  }
}

