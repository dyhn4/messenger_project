import 'package:flutter/material.dart';

import '../../models/groupware.dart' show minutesText;
import '../../models/groupware_resources.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareSectionHeader;
import 'resource_tab.dart' show bookingRangeText;
import '../../l10n/tr.dart';

/// "예약" 탭 후속의 조각들 — 자원 예약 규칙(요일·시간대·한 번에 쓸 수 있는 시간 — 서버 resourcePolicy.js)을 글로 옮기는 도우미와
/// 승인할 사람·관리자가 보는 "승인 기다리는 예약" 칸([PendingBookingsSection]). 예약 창·시간표는 resource_tab.dart, 관리 탭의 규칙·
/// 태블릿 화면·통계는 resource_admin_extras.dart.

/// 요일 이름 — 서버와 같은 번호(0=일 ~ 6=토).
final resourceDayNames = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

/// 화면에 늘어놓는 요일 순서 — 월요일부터(번호는 서버 것 그대로).
const resourceDayOrder = [1, 2, 3, 4, 5, 6, 0];

/// 분 → "2시간" · "1시간 30분" · "45분" · "3일"(서버 resourcePolicy.js durationText와 같은 모양 — 오류 글과 맞춘다).
String resourceDurationText(int minutes) {
  if (minutes > 0 && minutes % (24 * 60) == 0) {
    return tr('{n}일', {'n': minutes ~/ (24 * 60)});
  }
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h > 0 && m > 0) return tr('{h}시간 {m}분', {'h': h, 'm': m});
  if (h > 0) return tr('{h}시간', {'h': h});
  return tr('{m}분', {'m': m});
}

/// 요일 목록(0=일) → "월·수·금"(월요일부터).
String resourceDaysText(List<int> days) => [
  for (final d in resourceDayOrder)
    if (days.contains(d)) resourceDayNames[d],
].join('·');

/// 예약 규칙 조각 — "월·화·수·목·금요일", "09:00~18:00", "한 번에 2시간까지". 규칙이 없으면 빈 목록(예약할 수 있는 사람·승인은
/// 따로 — [GroupwareResource.canBook]·[GroupwareResource.needsApproval]).
List<String> resourceRuleParts(GroupwareResource r) => [
  if (r.availableDays != null)
    tr('{days}요일', {'days': resourceDaysText(r.availableDays!)}),
  if (r.availableFrom != null && r.availableTo != null)
    '${minutesText(r.availableFrom!)}~${minutesText(r.availableTo!)}',
  if (r.maxMinutes != null)
    tr('한 번에 {d}까지', {'d': resourceDurationText(r.maxMinutes!)}),
];

/// 승인 기다리는 예약(GET /groupware/bookings/pending — 그룹웨어 관리자는 범위 전부, 아니면 내가 승인할 사람인 자원의 것). 비어 있으면
/// 아무것도 그리지 않는다. 승인·거절(사유를 잡은 사람에게 알림)하고, 반복 예약이면 "반복 모두"(이 회차와 그 뒤 기다리는 회차)를 고를 수 있다.
/// 처리하면 [onChanged] — 탭이 현황을 다시 받는다(서버도 groupware:changed를 보낸다).
class PendingBookingsSection extends StatefulWidget {
  final GroupwareApi api;
  final List<ResourceBooking> pending;
  final VoidCallback onChanged;
  const PendingBookingsSection({
    super.key,
    required this.api,
    required this.pending,
    required this.onChanged,
  });

  @override
  State<PendingBookingsSection> createState() => _PendingBookingsSectionState();
}

class _PendingBookingsSectionState extends State<PendingBookingsSection> {
  /// 처리 중인 예약 id — 두 번 누르지 않게 그 줄의 단추를 끈다.
  final _busy = <String>{};

  Future<void> _approve(ResourceBooking b) async {
    var series = false;
    if (b.seriesId != null) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('반복 예약 승인')),
          content: Text(tr('이 회차만 승인할까요, 이 회차와 뒤에 기다리는 회차를 모두 승인할까요?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(tr('취소')),
            ),
            TextButton(
              key: const ValueKey('booking-approve-one'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('이 회차만')),
            ),
            FilledButton(
              key: const ValueKey('booking-approve-series'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('반복 모두')),
            ),
          ],
        ),
      );
      if (choice == null) return;
      series = choice;
    }
    await _decide(b, approve: true, series: series);
  }

  Future<void> _reject(ResourceBooking b) async {
    final result = await showDialog<({String reason, bool series})>(
      context: context,
      builder: (_) => _RejectBookingDialog(booking: b),
    );
    if (result == null) return;
    await _decide(
      b,
      approve: false,
      reason: result.reason.isEmpty ? null : result.reason,
      series: result.series,
    );
  }

  Future<void> _decide(
    ResourceBooking b, {
    required bool approve,
    String? reason,
    bool series = false,
  }) async {
    setState(() => _busy.add(b.id));
    try {
      await widget.api.decideBooking(
        b.id,
        approve: approve,
        reason: reason,
        series: series,
      );
      if (mounted) {
        showAppToast(
          context,
          approve ? tr('승인했습니다.') : tr('거절했습니다 — 잡은 사람에게 알립니다.'),
        );
      }
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('처리하지 못했습니다.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(b.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pending.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('booking-pending-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(tr('승인 기다리는 예약')),
        for (final b in widget.pending)
          ListTile(
            key: ValueKey('booking-pending-${b.id}'),
            dense: true,
            leading: Icon(
              b.seriesId != null ? Icons.repeat : Icons.hourglass_top,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              '${b.resourceName} · ${b.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                bookingRangeText(b),
                b.userName,
                if (b.seriesId != null) tr('반복 예약'),
              ].join(' · '),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('booking-approve-${b.id}'),
                  tooltip: tr('승인'),
                  icon: Icon(
                    Icons.check_circle_outline,
                    color: Colors.green.shade700,
                  ),
                  onPressed: _busy.contains(b.id) ? null : () => _approve(b),
                ),
                IconButton(
                  key: ValueKey('booking-reject-${b.id}'),
                  tooltip: tr('거절'),
                  icon: Icon(
                    Icons.cancel_outlined,
                    color: theme.colorScheme.error,
                  ),
                  onPressed: _busy.contains(b.id) ? null : () => _reject(b),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 거절 창 — 사유(비워도 됨 — 잡은 사람에게 알림에 붙는다)와, 반복 예약이면 "이 회차와 뒤에 기다리는 회차 모두".
class _RejectBookingDialog extends StatefulWidget {
  final ResourceBooking booking;
  const _RejectBookingDialog({required this.booking});

  @override
  State<_RejectBookingDialog> createState() => _RejectBookingDialogState();
}

class _RejectBookingDialogState extends State<_RejectBookingDialog> {
  final _reason = TextEditingController();
  bool _series = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    return AlertDialog(
      title: Text(tr('예약 거절')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${b.resourceName} · ${bookingRangeText(b)} · ${b.userName}'),
            TextField(
              key: const ValueKey('booking-reject-reason'),
              controller: _reason,
              maxLength: 200,
              decoration: InputDecoration(labelText: tr('사유 (잡은 사람에게 알립니다)')),
            ),
            if (b.seriesId != null)
              CheckboxListTile(
                key: const ValueKey('booking-reject-series'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _series,
                onChanged: (v) => setState(() => _series = v ?? false),
                title: Text(tr('반복 모두 (이 회차와 뒤에 기다리는 회차)')),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('booking-reject-confirm'),
          onPressed: () => Navigator.of(
            context,
          ).pop((reason: _reason.text.trim(), series: _series)),
          child: Text(tr('거절')),
        ),
      ],
    );
  }
}
