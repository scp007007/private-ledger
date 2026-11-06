import '../l10n/ledger_l10n.dart';
import 'package:flutter/material.dart';

import '../ledger_controller.dart';

class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.controller});

  final LedgerController controller;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await widget.controller.refreshRules();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, "暂时无法读取服务器规则，显示本地缓存：{0}", [localizedProblem(context, error)]))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, "删除规则？")),
        content: Text(tr(context, "已经导入的流水不会改变。")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, "取消")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, "删除")),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.controller.deleteRule('${rule['id']}');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, "删除失败：{0}", [localizedProblem(context, error)]))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = widget.controller.rules;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, "自动分类规则"))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(context, "规则会在以后导入账单时自动运行；人工修改始终优先。新建规则不会追改已经导入的流水。")),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          if (rules.isEmpty)
            Padding(
              padding: EdgeInsets.all(20),
              child: Text(tr(context, "还没有规则。可以用商户或描述关键词快速归类。")),
            ),
          for (final rule in rules)
            Card(
              child: ListTile(
                title: Text(
                  _describeConditions(context,
                    (rule['conditions'] as Map<String, dynamic>?) ?? const {},
                  ),
                ),
                subtitle: Text(
                  _describeActions(context,
                    (rule['actions'] as Map<String, dynamic>?) ?? const {},
                  ),
                ),
                trailing: IconButton(
                  tooltip: tr(context, "删除规则"),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy ? null : () => _delete(rule),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NewRulePage(controller: widget.controller),
                ),
              ),
        icon: const Icon(Icons.add),
        label: Text(tr(context, "新建规则")),
      ),
    );
  }
}

String _describeConditions(BuildContext context, Map<String, dynamic> conditions) {
  final parts = <String>[];
  if (conditions['merchant_contains'] != null) {
    parts.add(tr(context, "商户含「{0}」", [conditions['merchant_contains']]));
  }
  if (conditions['description_contains'] != null) {
    parts.add(tr(context, "描述含「{0}」", [conditions['description_contains']]));
  }
  for (final key in ['source', 'kind', 'direction']) {
    if (conditions[key] != null) parts.add('$key = ${conditions[key]}');
  }
  return parts.join(tr(context, " 且 "));
}

String _describeActions(BuildContext context, Map<String, dynamic> actions) {
  final parts = <String>[];
  if (actions.containsKey('category')) parts.add(tr(context, "分类：{0}", [actions['category']]));
  if (actions.containsKey('tags')) {
    parts.add(tr(context, "标签：{0}", [(actions['tags'] as List<dynamic>).join('、')]));
  }
  if (actions.containsKey('excluded')) {
    parts.add(actions['excluded'] == true ? tr(context, "排除统计") : tr(context, "计入统计"));
  }
  return parts.join(' · ');
}

class NewRulePage extends StatefulWidget {
  const NewRulePage({super.key, required this.controller});

  final LedgerController controller;

  @override
  State<NewRulePage> createState() => _NewRulePageState();
}

class _NewRulePageState extends State<NewRulePage> {
  final _merchant = TextEditingController();
  final _description = TextEditingController();
  final _category = TextEditingController();
  final _tags = TextEditingController();
  String? _source;
  String? _kind;
  String? _direction;
  String _exclusion = 'unchanged';
  bool _busy = false;

  @override
  void dispose() {
    _merchant.dispose();
    _description.dispose();
    _category.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final conditions = <String, dynamic>{};
    final actions = <String, dynamic>{};
    if (_merchant.text.trim().isNotEmpty) {
      conditions['merchant_contains'] = _merchant.text.trim();
    }
    if (_description.text.trim().isNotEmpty) {
      conditions['description_contains'] = _description.text.trim();
    }
    if (_source != null) conditions['source'] = _source;
    if (_kind != null) conditions['kind'] = _kind;
    if (_direction != null) conditions['direction'] = _direction;
    if (_category.text.trim().isNotEmpty) {
      actions['category'] = _category.text.trim();
    }
    final tags = _tags.text
        .split(RegExp(r'[,，、]'))
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (tags.isNotEmpty) actions['tags'] = tags;
    if (_exclusion != 'unchanged') {
      actions['excluded'] = _exclusion == 'exclude';
    }
    if (conditions.isEmpty || actions.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, "至少填写一个匹配条件和一个处理动作。"))));
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.createRule(conditions, actions);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, "保存规则失败：{0}", [localizedProblem(context, error)]))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, "新建规则"))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(context, "匹配条件"), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            controller: _merchant,
            decoration: InputDecoration(
              labelText: tr(context, "商户名称包含"),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            decoration: InputDecoration(
              labelText: tr(context, "交易描述包含"),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          _dropdown(tr(context, "来源"), _source, {
            'wechat': tr(context, "微信"),
            'alipay': tr(context, "支付宝"),
            'generic': tr(context, "标准 CSV"),
          }, (value) => setState(() => _source = value)),
          const SizedBox(height: 10),
          _dropdown(tr(context, "交易性质"), _kind, {
            'payment': tr(context, "消费"),
            'refund': tr(context, "退款"),
            'transfer': tr(context, "转账"),
            'red_packet': tr(context, "红包"),
            'other': tr(context, "其他"),
          }, (value) => setState(() => _kind = value)),
          const SizedBox(height: 10),
          _dropdown(tr(context, "收支方向"), _direction, {
            'expense': tr(context, "支出"),
            'income': tr(context, "收入"),
          }, (value) => setState(() => _direction = value)),
          const SizedBox(height: 22),
          Text(tr(context, "自动处理"), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            controller: _category,
            decoration: InputDecoration(
              labelText: tr(context, "设为分类"),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tags,
            decoration: InputDecoration(
              labelText: tr(context, "添加标签（逗号分隔）"),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _exclusion,
            decoration: InputDecoration(
              labelText: tr(context, "统计处理"),
              border: OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(value: 'unchanged', child: Text(tr(context, "不更改"))),
              DropdownMenuItem(value: 'exclude', child: Text(tr(context, "排除统计"))),
              DropdownMenuItem(value: 'include', child: Text(tr(context, "计入统计"))),
            ],
            onChanged: (value) =>
                setState(() => _exclusion = value ?? 'unchanged'),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? tr(context, "保存中…") : tr(context, "保存规则")),
          ),
          const SizedBox(height: 10),
          Text(tr(context, "条件同时满足才会触发。规则仅用于未来导入的账单，已手动修改的记录不会被覆盖。")),
        ],
      ),
    );
  }

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> options,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        DropdownMenuItem<String>(value: null, child: Text(tr(context, "任何"))),
        for (final option in options.entries)
          DropdownMenuItem(value: option.key, child: Text(option.value)),
      ],
      onChanged: onChanged,
    );
  }
}
