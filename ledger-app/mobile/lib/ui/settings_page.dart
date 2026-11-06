import '../l10n/ledger_l10n.dart';
import 'package:flutter/material.dart';

import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';
import 'connection_screen.dart';
import 'language_picker.dart';
import 'rules_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final LedgerController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _savingRedPacket = false;
  bool _savingAppearance = false;

  Future<void> _setAppearance(String? value) async {
    if (value == null) return;
    setState(() => _savingAppearance = true);
    try {
      await widget.controller.setAppearance(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, "外观设置未保存，请重试。"))));
      }
    } finally {
      if (mounted) setState(() => _savingAppearance = false);
    }
  }

  Future<void> _setRedPacket(bool value) async {
    setState(() => _savingRedPacket = true);
    try {
      await widget.controller.setExcludeRedPackets(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, "设置失败：{0}", [localizedProblem(context, error)]))));
      }
    } finally {
      if (mounted) setState(() => _savingRedPacket = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final syncLabel = controller.syncing
            ? tr(context, "正在同步")
            : controller.lastError != null
            ? tr(context, "同步未完成")
            : controller.pendingCount > 0
            ? tr(context, "{0} 项修改待同步", [controller.pendingCount])
            : controller.lastSyncAt == null ? tr(context, "尚未同步") : tr(context, "已同步");
        return ListView(
          key: const PageStorageKey('settings-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(children: [
                  Container(
                    width: 54, height: 54,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(Icons.account_balance_wallet_outlined,
                      color: colors.onPrimaryContainer, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr(context, "私人账本"), style: theme.textTheme.titleLarge),
                      const SizedBox(height: 5),
                      Text(tr(context, "本机 + 自有电脑\n已保存 {0} 笔流水", [controller.rows.length]),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant, height: 1.6)),
                    ],
                  )),
                ]),
              ),
            ),
            _sectionTitle(tr(context, "界面外观")),
            Card(child: Padding(
              padding: const EdgeInsets.all(18),
              child: LanguagePicker(controller: controller),
            )),
            Card(child: Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Icon(Icons.palette_outlined, size: 20, color: colors.primary),
                  const SizedBox(width: 10), Text(tr(context, "选择外观"), style: theme.textTheme.titleSmall)]),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: controller.appearance, isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: 'light', child: Text(tr(context, "浅灰与蓝色"))),
                    DropdownMenuItem(value: 'dark', child: Text(tr(context, "深色"))),
                    DropdownMenuItem(value: 'system', child: Text(tr(context, "跟随系统"))),
                  ],
                  onChanged: _savingAppearance ? null : _setAppearance,
                ),
                Text(tr(context, "默认使用浅色，选择会保存在这台设备上。"), style: theme.textTheme.bodySmall),
              ]))),
            _sectionTitle(tr(context, "同步状态")),
            Card(child: SwitchListTile(
              title: Text(tr(context, "自动同步手机与电脑账本")),
              subtitle: Text(tr(context, "打开或回到应用、保存修改及前台每 60 秒尝试。不是自动读取支付账户；后台或电脑断网时等待恢复。")),
              value: controller.autoSync,
              onChanged: (value) async {
                try { await controller.setAutoSync(value); }
                catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, "同步设置未保存，请重试。")))); }
              },
            )),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Icon(controller.lastError == null
                        ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                        color: colors.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(syncLabel, style: theme.textTheme.titleSmall)),
                    ]),
                    const SizedBox(height: 10),
                    Text(controller.lastSyncAt == null
                      ? tr(context, "连接服务器后，账单和修改会自动同步。")
                      : tr(context, "上次成功：{0}", [formatDate(controller.lastSyncAt!)]),
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Text(tr(context, "待同步修改：{0} 项", [controller.pendingCount]),
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                    if (controller.lastError != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(localizedProblem(context, controller.lastError!), style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onErrorContainer)),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => ConnectionScreen(controller: controller))),
                        icon: const Icon(Icons.network_check),
                        label: Text(tr(context, "检查连接与修复地址")),
                      ),
                    ],
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: controller.syncing ? null : controller.syncNow,
                      icon: const Icon(Icons.sync_rounded),
                      label: Text(controller.syncing ? tr(context, "正在同步…") : tr(context, "立即同步")),
                    ),
                  ],
                ),
              ),
            ),
            _sectionTitle(tr(context, "统计口径")),
            Card(
              child: Column(children: [
                SwitchListTile.adaptive(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  title: Text(tr(context, "排除收发红包")),
                  subtitle: Text(tr(context, "保留原始流水，更新此设置需要联网")),
                  value: controller.excludeRedPackets,
                  onChanged: _savingRedPacket ? null : _setRedPacket,
                ),
                if (_savingRedPacket) const LinearProgressIndicator(),
                const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                  title: Text(tr(context, "账户间转账")),
                  subtitle: Text(tr(context, "默认不计入收支")),
                  leading: Icon(Icons.swap_horiz_rounded),
                ),
                const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                  title: Text(tr(context, "退款抵扣")),
                  subtitle: Text(tr(context, "关联后抵扣原消费月份；未关联时单独提示")),
                  leading: Icon(Icons.undo_rounded),
                ),
              ]),
            ),
            _sectionTitle(tr(context, "账本管理")),
            Card(
              child: Column(children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: Icon(Icons.auto_fix_high_outlined, color: colors.primary),
                  title: Text(tr(context, "自动分类规则")),
                  subtitle: Text(tr(context, "已保存 {0} 条 · 用于后续导入", [controller.rules.length])),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => RulesPage(controller: controller))),
                ),
                const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: Icon(Icons.dns_outlined, color: colors.primary),
                  title: Text(tr(context, "连接设置")),
                  subtitle: Text(controller.baseUrl ?? tr(context, "连接自己的账本服务器"),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => ConnectionScreen(controller: controller))),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            Text(tr(context, "离线记账和修改会即时更新本机统计。\n连接电脑后，可同步账单流水。"),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.7)),
          ],
        );
      },
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
