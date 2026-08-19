/// MonitorGpuTool 支持的 OpenAI 兼容供应商预设。
library;

class LlmProviderPreset {
  final String id;
  final String label;
  final String baseUrl;
  final List<String> models;
  final bool requiresApiKey;
  final String hint;

  const LlmProviderPreset({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.models,
    this.requiresApiKey = true,
    required this.hint,
  });

  String get defaultModel => models.isEmpty ? '' : models.first;
}

const llmProviders = <LlmProviderPreset>[
  LlmProviderPreset(
    id: 'deepseek',
    label: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    models: ['deepseek-v4-flash', 'deepseek-v4-pro'],
    hint: '适合中文报错总结，速度快、成本低',
  ),
  LlmProviderPreset(
    id: 'qwen',
    label: '通义千问',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    models: ['qwen3.7-flash', 'qwen3.7-plus', 'qwen3.7-max'],
    hint: '默认使用阿里云北京区公共兼容地址',
  ),
  LlmProviderPreset(
    id: 'kimi',
    label: 'Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    models: ['kimi-k2.6', 'kimi-k3'],
    hint: '月之暗面中国区 OpenAI 兼容接口',
  ),
  LlmProviderPreset(
    id: 'openai',
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-5.4-mini', 'gpt-5.4-nano', 'gpt-5.4'],
    hint: '需要服务器能够访问 OpenAI API',
  ),
  LlmProviderPreset(
    id: 'ollama',
    label: 'Ollama（本地）',
    baseUrl: 'http://127.0.0.1:11434/v1',
    models: [],
    requiresApiKey: false,
    hint: '模型名按服务器 ollama list 的结果填写',
  ),
  LlmProviderPreset(
    id: 'custom',
    label: '自定义兼容接口',
    baseUrl: '',
    models: [],
    requiresApiKey: false,
    hint: '填写任意 OpenAI Chat Completions 兼容地址',
  ),
];

LlmProviderPreset llmProviderById(String? id) => llmProviders.firstWhere(
  (provider) => provider.id == id,
  orElse: () => llmProviders.last,
);
