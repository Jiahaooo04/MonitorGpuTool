/// Hallmark · pre-emit critique: P5 H5 E5 S5 R4 V4
/// Hallmark · component: server LLM settings sheet · genre: playful
/// theme: Hum quiet register · states: loading/default/focus/disabled/error/success
library;

import 'package:flutter/material.dart';

import '../llm_provider.dart';
import '../state.dart';
import '../ui.dart';

typedef LlmCommand =
    Future<Map<String, dynamic>> Function(String op, Map<String, dynamic> args);

Future<void> showLlmSettingsSheet(
  BuildContext context,
  String agentId,
  String serverName,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Rm.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => LlmSettingsSheet(
      serverName: serverName,
      command: (op, args) => appState.sendCmd(agentId, op, '', args),
    ),
  );
}

class LlmSettingsSheet extends StatefulWidget {
  final String serverName;
  final LlmCommand command;

  const LlmSettingsSheet({
    super.key,
    required this.serverName,
    required this.command,
  });

  @override
  State<LlmSettingsSheet> createState() => _LlmSettingsSheetState();
}

class _LlmSettingsSheetState extends State<LlmSettingsSheet> {
  static const _customModel = '__custom__';

  final _baseUrlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  LlmProviderPreset _provider = llmProviderById('deepseek');
  String _modelChoice = '';
  bool _enabled = true;
  bool _apiKeySet = false;
  bool _obscureKey = true;
  bool _loading = true;
  bool _testing = false;
  bool _saving = false;
  bool? _testOk;
  String? _statusTitle;
  String? _statusBody;

  @override
  void initState() {
    super.initState();
    _applyProvider(_provider, resetEndpoint: true);
    _load();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await widget.command('llm_config_get', const {});
    if (!mounted) return;
    if (result['ok'] == true) {
      final provider = llmProviderById(result['provider'] as String?);
      final baseUrl = (result['base_url'] as String? ?? '').trim();
      final model = (result['model'] as String? ?? '').trim();
      setState(() {
        _provider = provider;
        _enabled = result['enabled'] == true;
        _apiKeySet = result['api_key_set'] == true;
        _baseUrlCtrl.text = baseUrl.isNotEmpty ? baseUrl : provider.baseUrl;
        if (provider.models.contains(model)) {
          _modelChoice = model;
          _modelCtrl.clear();
        } else {
          _modelChoice = provider.models.isEmpty ? _customModel : _customModel;
          _modelCtrl.text = model;
        }
        _loading = false;
      });
    } else {
      setState(() {
        _loading = false;
        _testOk = false;
        _statusTitle = '读取失败';
        _statusBody = result['error'] as String? ?? '服务器没有响应';
      });
    }
  }

  void _applyProvider(
    LlmProviderPreset provider, {
    required bool resetEndpoint,
  }) {
    _provider = provider;
    if (resetEndpoint) _baseUrlCtrl.text = provider.baseUrl;
    if (provider.models.isEmpty) {
      _modelChoice = _customModel;
      _modelCtrl.clear();
    } else {
      _modelChoice = provider.defaultModel;
      _modelCtrl.clear();
    }
    _clearTestResult();
  }

  void _clearTestResult() {
    _testOk = null;
    _statusTitle = null;
    _statusBody = null;
  }

  String get _model =>
      _modelChoice == _customModel ? _modelCtrl.text.trim() : _modelChoice;

  Map<String, dynamic>? _formArgs() {
    final baseUrl = _baseUrlCtrl.text.trim();
    final model = _model;
    if (baseUrl.isEmpty ||
        !(baseUrl.startsWith('http://') || baseUrl.startsWith('https://'))) {
      _showLocalError('接口地址不完整', '请填写以 http:// 或 https:// 开头的地址。');
      return null;
    }
    if (model.isEmpty) {
      _showLocalError('还没有模型', '请选择一个模型，或填写自定义模型名称。');
      return null;
    }
    if (_provider.requiresApiKey &&
        !_apiKeySet &&
        _apiKeyCtrl.text.trim().isEmpty) {
      _showLocalError('还没有 API Key', '填入这家供应商生成的 API Key 后再测试。');
      return null;
    }
    final args = <String, dynamic>{
      'enabled': _enabled,
      'provider': _provider.id,
      'base_url': baseUrl,
      'model': model,
    };
    final apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isNotEmpty) args['api_key'] = apiKey;
    return args;
  }

  void _showLocalError(String title, String body) {
    setState(() {
      _testOk = false;
      _statusTitle = title;
      _statusBody = body;
    });
  }

  Future<void> _test() async {
    final args = _formArgs();
    if (args == null) return;
    setState(() {
      _testing = true;
      _clearTestResult();
    });
    final result = await widget.command('llm_test', args);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result['ok'] == true;
      _statusTitle = _testOk! ? '测试通过' : '测试失败';
      _statusBody = _testOk!
          ? result['summary'] as String? ?? '接口响应正常'
          : result['error'] as String? ?? '服务器没有返回具体原因';
    });
  }

  Future<void> _save() async {
    final args = _formArgs();
    if (args == null) return;
    setState(() => _saving = true);
    final result = await widget.command('llm_config_set', args);
    if (!mounted) return;
    setState(() => _saving = false);
    if (result['ok'] == true) {
      _apiKeyCtrl.clear();
      _apiKeySet = result['api_key_set'] == true || _apiKeySet;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.maybePop(context);
      messenger?.showSnackBar(
        SnackBar(content: Text('已保存到「${widget.serverName}」')),
      );
    } else {
      _showLocalError('保存失败', result['error'] as String? ?? '服务器没有返回具体原因');
    }
  }

  InputDecoration _decoration({required String hint, Widget? suffix}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: sans(size: 12.5, color: Rm.inkFaint),
        filled: true,
        fillColor: Rm.card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        suffixIcon: suffix,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Rm.radiusInput),
          borderSide: const BorderSide(color: Rm.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Rm.radiusInput),
          borderSide: const BorderSide(color: Rm.pearDeep),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Rm.radiusInput),
          borderSide: const BorderSide(color: Rm.coralDeep),
        ),
      );

  Widget _fieldLabel(String label, {String? helper}) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 7),
    child: Row(
      children: [
        Text(label, style: sans(size: 13, weight: FontWeight.w600)),
        if (helper != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              helper,
              textAlign: TextAlign.right,
              style: sans(size: 11.5, color: Rm.inkFaint),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _statusCard() {
    if (_statusTitle == null) return const SizedBox.shrink();
    final success = _testOk == true;
    final deep = success ? Rm.mintDeep : Rm.coralDeep;
    final tint = success ? Rm.mintTint : Rm.coralTint;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey('$_statusTitle$_statusBody'),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(Rm.radiusInput),
          border: Border.all(color: deep.withValues(alpha: 0.22)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              success ? Icons.check_circle_outline : Icons.error_outline,
              size: 19,
              color: deep,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusTitle!,
                    style: sans(
                      size: 13.5,
                      weight: FontWeight.w700,
                      color: deep,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _statusBody ?? '',
                    style: sans(size: 12.5, color: deep, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final busy = _loading || _testing || _saving;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.serverName} · 报错总结',
                style: sans(size: 18, weight: FontWeight.w700, spacing: -0.3),
              ),
              const SizedBox(height: 6),
              Text(
                '任务报错后，让这台服务器调用你选择的模型，把日志变成一两句易读说明。',
                style: sans(size: 12.5, color: Rm.inkSoft, height: 1.5),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: Rm.cyanTint,
                  borderRadius: BorderRadius.circular(Rm.radiusInput),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.lock_outline_rounded,
                      size: 18,
                      color: Rm.cyanDeep,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'API Key 经端到端加密发到 Agent，只保存在这台服务器；Relay 不会看到明文。报错日志会发送给你选择的模型供应商。',
                        style: sans(
                          size: 11.8,
                          color: Rm.cyanDeep,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(color: Rm.pearDeep),
                  ),
                )
              else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '报错时自动总结',
                    style: sans(size: 14.5, weight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '关闭后保留配置，但不会调用模型',
                    style: sans(size: 12, color: Rm.inkFaint),
                  ),
                  value: _enabled,
                  activeThumbColor: Rm.pearDeep,
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          _enabled = value;
                          _clearTestResult();
                        }),
                ),
                const SizedBox(height: 8),
                _fieldLabel('供应商', helper: _provider.hint),
                DropdownButtonFormField<String>(
                  initialValue: _provider.id,
                  isExpanded: true,
                  decoration: _decoration(hint: '选择供应商'),
                  items: [
                    for (final provider in llmProviders)
                      DropdownMenuItem(
                        value: provider.id,
                        child: Text(provider.label),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (id) => setState(
                          () => _applyProvider(
                            llmProviderById(id),
                            resetEndpoint: true,
                          ),
                        ),
                ),
                const SizedBox(height: 14),
                _fieldLabel('接口地址'),
                TextField(
                  controller: _baseUrlCtrl,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: mono(size: 12.5, color: Rm.ink),
                  onChanged: (_) => setState(_clearTestResult),
                  decoration: _decoration(hint: 'https://example.com/v1'),
                ),
                const SizedBox(height: 14),
                _fieldLabel('模型'),
                if (_provider.models.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('model-${_provider.id}-$_modelChoice'),
                    initialValue: _modelChoice,
                    isExpanded: true,
                    decoration: _decoration(hint: '选择模型'),
                    items: [
                      for (final model in _provider.models)
                        DropdownMenuItem(
                          value: model,
                          child: Text(model, style: mono(size: 12.5)),
                        ),
                      const DropdownMenuItem(
                        value: _customModel,
                        child: Text('自定义模型…'),
                      ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            _modelChoice = value ?? _provider.defaultModel;
                            _clearTestResult();
                          }),
                  ),
                  if (_modelChoice == _customModel) const SizedBox(height: 8),
                ],
                if (_provider.models.isEmpty || _modelChoice == _customModel)
                  TextField(
                    controller: _modelCtrl,
                    enabled: !busy,
                    autocorrect: false,
                    style: mono(size: 12.5, color: Rm.ink),
                    onChanged: (_) => setState(_clearTestResult),
                    decoration: _decoration(
                      hint: _provider.id == 'ollama'
                          ? '例如 llama3.2（以 ollama list 为准）'
                          : '填写模型 ID',
                    ),
                  ),
                const SizedBox(height: 14),
                _fieldLabel('API Key', helper: _apiKeySet ? '这台服务器已保存' : null),
                TextField(
                  controller: _apiKeyCtrl,
                  enabled: !busy,
                  obscureText: _obscureKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: mono(size: 13, color: Rm.ink),
                  onChanged: (_) => setState(_clearTestResult),
                  decoration: _decoration(
                    hint: _apiKeySet
                        ? '已保存；留空保持不变'
                        : (_provider.requiresApiKey ? '粘贴 API Key' : '可选'),
                    suffix: IconButton(
                      tooltip: _obscureKey ? '显示 API Key' : '隐藏 API Key',
                      onPressed: busy
                          ? null
                          : () => setState(() => _obscureKey = !_obscureKey),
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 19,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _statusCard(),
                if (_statusTitle != null) const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: SoftButton(
                        label: _testing ? '测试中…' : '测试连接',
                        icon: Icons.network_check_rounded,
                        deep: Rm.cyanDeep,
                        tint: Rm.cyanTint,
                        onPressed: busy ? null : _test,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Center(
                        child: PushButton(
                          label: _saving ? '保存中…' : '保存配置',
                          icon: Icons.save_outlined,
                          onPressed: busy ? null : _save,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
