import 'package:flutter/material.dart';

import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';
import 'connection_screen.dart';
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
          const SnackBar(content: Text('外观设置未保存，请重试。')));
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
        ).showSnackBar(SnackBar(content: Text('设置失败：$error')));
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
            ? '正在同步'
            : controller.lastError != null
            ? '同步未完成'
            : controller.pendingCount > 0
            ? '${controller.pendingCount} 项修改待同步'
            : controller.lastSyncAt == null ? '尚未同步' : '已同步';
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
                      Text('私人账本', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 5),
                      Text('本机 + 自有电脑\n已保存 ${controller.rows.length} 笔流水',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant, height: 1.6)),
                    ],
                  )),
                ]),
              ),
            ),
            _sectionTitle('界面外观'),
            Card(child: Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Icon(Icons.palette_outlined, size: 20, color: colors.primary),
                  const SizedBox(width: 10), Text('选择外观', style: theme.textTheme.titleSmall)]),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: controller.appearance, isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'light', child: Text('浅灰与蓝色')),
                    DropdownMenuItem(value: 'dark', child: Text('深色')),
                    DropdownMenuItem(value: 'system', child: Text('跟随系统')),
                  ],
                  onChanged: _savingAppearance ? null : _setAppearance,
                ),
                Text('默认使用浅色，选择会保存在这台设备上。', style: theme.textTheme.bodySmall),
              ]))),
            _sectionTitle('同步状态'),
            Card(child: SwitchListTile(
              title: const Text('自动同步手机与电脑账本'),
              subtitle: const Text('打开或回到应用、保存修改及前台每 60 秒尝试。不是自动读取支付账户；后台或电脑断网时等待恢复。'),
              value: controller.autoSync,
              onChanged: (value) async {
                try { await controller.setAutoSync(value); }
                catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('同步设置未保存，请重试。'))); }
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
                      ? '连接服务器后，账单和修改会自动同步。'
                      : '上次成功：${formatDate(controller.lastSyncAt!)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Text('待同步修改：${controller.pendingCount} 项',
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                    if (controller.lastError != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(controller.lastError!, style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onErrorContainer)),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => ConnectionScreen(controller: controller))),
                        icon: const Icon(Icons.network_check),
                        label: const Text('检查连接与修复地址'),
                      ),
                    ],
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: controller.syncing ? null : controller.syncNow,
                      icon: const Icon(Icons.sync_rounded),
                      label: Text(controller.syncing ? '正在同步…' : '立即同步'),
                    ),
                  ],
                ),
              ),
            ),
            _sectionTitle('统计口径'),
            Card(
              child: Column(children: [
                SwitchListTile.adaptive(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  title: const Text('排除收发红包'),
                  subtitle: const Text('保留原始流水，更新此设置需要联网'),
                  value: controller.excludeRedPackets,
                  onChanged: _savingRedPacket ? null : _setRedPacket,
                ),
                if (_savingRedPacket) const LinearProgressIndicator(),
                const Divider(height: 1, indent: 18, endIndent: 18),
                const ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                  title: Text('账户间转账'),
                  subtitle: Text('默认不计入收支'),
                  leading: Icon(Icons.swap_horiz_rounded),
                ),
                const Divider(height: 1, indent: 18, endIndent: 18),
                const ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                  title: Text('退款抵扣'),
                  subtitle: Text('关联后抵扣原消费月份；未关联时单独提示'),
                  leading: Icon(Icons.undo_rounded),
                ),
              ]),
            ),
            _sectionTitle('账本管理'),
            Card(
              child: Column(children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: Icon(Icons.auto_fix_high_outlined, color: colors.primary),
                  title: const Text('自动分类规则'),
                  subtitle: Text('已保存 ${controller.rules.length} 条 · 用于后续导入'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => RulesPage(controller: controller))),
                ),
                const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: Icon(Icons.dns_outlined, color: colors.primary),
                  title: const Text('连接设置'),
                  subtitle: Text(controller.baseUrl ?? '连接自己的账本服务器',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => ConnectionScreen(controller: controller))),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            Text('离线记账和修改会即时更新本机统计。\n连接电脑后，可同步账单流水。',
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
