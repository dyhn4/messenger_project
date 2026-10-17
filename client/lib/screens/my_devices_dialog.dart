import 'package:flutter/material.dart';

import '../models/my_device.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';

/// "로그인한 기기" — 내 계정으로 로그인한 기기(PC 앱·안드로이드·웹 브라우저)를 보여 주고, 기기마다 로그아웃시키거나 이 기기
/// 말고 전부 로그아웃시킨다(server/src/devices.js). 공용 PC에서 로그아웃을 잊었거나 휴대폰을 잃어버렸을 때 쓴다.
Future<void> showMyDevicesDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => MyDevicesDialog(session: session),
    );

class MyDevicesDialog extends StatefulWidget {
  final Session session;
  const MyDevicesDialog({super.key, required this.session});

  @override
  State<MyDevicesDialog> createState() => _MyDevicesDialogState();
}

class _MyDevicesDialogState extends State<MyDevicesDialog> {
  List<MyDevice>? _devices;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final devices = await widget.session.fetchMyDevices();
      if (mounted) setState(() => _devices = devices);
    } catch (e) {
      if (mounted) setState(() => _error = '기기 목록을 불러오지 못했습니다: $e');
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('my-devices-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _logout(MyDevice device) async {
    final ok = await _confirm(
      device.current ? '이 기기에서 로그아웃' : '기기 로그아웃',
      device.current
          ? '이 기기에서 로그아웃합니다.'
          : '${device.label}에서 로그아웃시킬까요? 그 기기는 다시 로그인해야 쓸 수 있고, 알림도 더 가지 않습니다.',
      '로그아웃',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.logoutDevice(device);
      if (!mounted) return;
      if (device.current) {
        Navigator.of(context).pop();
        return;
      }
      showAppToast(context, '${device.label}에서 로그아웃시켰습니다.');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '로그아웃시키지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logoutOthers() async {
    final ok = await _confirm(
      '다른 모든 기기에서 로그아웃',
      '이 기기 말고 내 계정으로 로그인한 모든 기기(PC·휴대폰·웹 브라우저)에서 로그아웃합니다. 앱을 업데이트하지 않아 목록에 '
          '보이지 않는 기기도 함께 로그아웃됩니다.',
      '모두 로그아웃',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await widget.session.logoutOtherDevices();
      if (!mounted) return;
      showAppToast(
        context,
        count > 0 ? '다른 기기 $count대에서 로그아웃시켰습니다.' : '다른 기기에서 로그아웃시켰습니다.',
      );
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '로그아웃시키지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData _icon(MyDevice d) => switch (d.kind) {
    'windows' => Icons.desktop_windows_outlined,
    'android' => Icons.phone_android,
    'ios' => Icons.phone_iphone,
    'web-desktop' => Icons.language,
    'web-android' || 'web-mobile' => Icons.smartphone_outlined,
    _ => Icons.devices_other,
  };

  String _subtitle(MyDevice d) {
    if (d.online) return d.current ? '이 기기 · 사용 중' : '지금 사용 중';
    final seen = d.lastSeenAt;
    final when = seen == null
        ? '처음 로그인 ${formatPostDateTime(d.createdAt)}'
        : '마지막 사용 ${formatPostDateTime(seen)}';
    return d.current ? '이 기기 · $when' : when;
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final hint = Theme.of(context).hintColor;
    final others = devices?.where((d) => !d.current).length ?? 0;
    return AlertDialog(
      title: const Text('로그인한 기기'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 420,
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: const Text('다시 시도')),
                  ],
                ),
              )
            : devices == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '공용 PC에서 로그아웃을 잊었거나 휴대폰을 잃어버렸으면 여기서 그 기기를 로그아웃시키세요.',
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                  for (final d in devices)
                    ListTile(
                      key: ValueKey('my-device-${d.id}'),
                      leading: Icon(_icon(d)),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              d.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (d.online) ...[
                            const SizedBox(width: 6),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(_subtitle(d)),
                      trailing: TextButton(
                        key: ValueKey('my-device-logout-${d.id}'),
                        onPressed: _busy ? null : () => _logout(d),
                        child: const Text('로그아웃'),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('my-devices-logout-others'),
          onPressed: _busy || devices == null ? null : _logoutOthers,
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          child: Text(
            others > 0 ? '다른 모든 기기에서 로그아웃 ($others대)' : '다른 모든 기기에서 로그아웃',
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
