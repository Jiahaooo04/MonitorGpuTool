import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmon_app/pages/llm_settings_sheet.dart';
import 'package:runmon_app/ui.dart';

void main() {
  testWidgets('服务器 LLM 配置可以获取、测试并保存', (tester) async {
    final calls = <(String, Map<String, dynamic>)>[];

    Future<Map<String, dynamic>> command(
      String op,
      Map<String, dynamic> args,
    ) async {
      calls.add((op, Map<String, dynamic>.from(args)));
      if (op == 'llm_config_get') {
        return {
          'ok': true,
          'enabled': true,
          'provider': 'deepseek',
          'base_url': 'https://api.deepseek.com',
          'model': 'deepseek-v4-flash',
          'api_key_set': true,
        };
      }
      if (op == 'llm_test') {
        return {'ok': true, 'summary': '可能是显存不足。建议减小 batch_size。'};
      }
      return {'ok': true, 'api_key_set': true};
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: LlmSettingsSheet(serverName: '实验室服务器', command: command),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('实验室服务器 · 报错总结'), findsOneWidget);
    expect(find.text('供应商'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.textContaining('已保存'), findsWidgets);

    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('测试通过'), findsOneWidget);
    expect(find.textContaining('显存不足'), findsOneWidget);
    expect(calls.where((c) => c.$1 == 'llm_test'), hasLength(1));

    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.$1 == 'llm_config_set'), hasLength(1));
    expect(calls.last.$2['provider'], 'deepseek');
    expect(calls.last.$2['model'], 'deepseek-v4-flash');
    expect(calls.last.$2.containsKey('api_key'), isFalse);
  });

  for (final width in [320.0, 375.0, 414.0, 768.0]) {
    testWidgets('LLM 配置在 ${width.round()}px 宽度无溢出', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);

      Future<Map<String, dynamic>> command(
        String op,
        Map<String, dynamic> _,
      ) async {
        return {
          'ok': true,
          'enabled': true,
          'provider': 'deepseek',
          'base_url': 'https://api.deepseek.com',
          'model': 'deepseek-v4-flash',
          'api_key_set': true,
        };
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: LlmSettingsSheet(serverName: '服务器', command: command),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('服务器 · 报错总结'), findsOneWidget);
    });
  }
}
