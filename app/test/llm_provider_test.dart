import 'package:flutter_test/flutter_test.dart';
import 'package:runmon_app/llm_provider.dart';

void main() {
  test('供应商预设包含常用国内外和本地接口', () {
    expect(llmProviderById('deepseek').baseUrl, 'https://api.deepseek.com');
    expect(
      llmProviderById('qwen').baseUrl,
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    );
    expect(llmProviderById('kimi').baseUrl, 'https://api.moonshot.cn/v1');
    expect(llmProviderById('openai').baseUrl, 'https://api.openai.com/v1');
    expect(llmProviderById('ollama').requiresApiKey, isFalse);
    expect(llmProviderById('custom').models, isEmpty);
  });

  test('未知供应商安全回退到自定义', () {
    expect(llmProviderById('future-provider').id, 'custom');
  });

  test('每个云供应商都有默认模型且允许自定义', () {
    for (final provider in llmProviders.where(
      (p) => p.id != 'custom' && p.id != 'ollama',
    )) {
      expect(provider.models, isNotEmpty, reason: provider.id);
      expect(provider.defaultModel, provider.models.first);
    }
  });
}
