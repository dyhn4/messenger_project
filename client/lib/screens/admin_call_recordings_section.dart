import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/call_recording.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart' show formatFileSize;
import '../l10n/tr.dart';

/// 관리자 콘솔 "운영 현황"의 화상회의 녹화 보관 — 녹화 파일의 보관 기간(일)·전체 용량(GB)을 정하면 서버가 넘는 만큼 오래된
/// 녹화 파일부터 지운다(server callRecordingRetention.js — 대화방의 파일은 "삭제된 파일", 회의록은 남음). 이 서버에 녹화가
/// 켜져 있지 않으면 아무것도 그리지 않는다.
class AdminCallRecordingsSection extends StatefulWidget {
  final Session session;
  const AdminCallRecordingsSection({super.key, required this.session});

  @override
  State<AdminCallRecordingsSection> createState() =>
      _AdminCallRecordingsSectionState();
}

class _AdminCallRecordingsSectionState
    extends State<AdminCallRecordingsSection> {
  CallRecordingRetention? _view;
  final _days = TextEditingController();
  final _gb = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _days.dispose();
    _gb.dispose();
    super.dispose();
  }

  void _show(CallRecordingRetention v) {
    _view = v;
    _days.text = v.retentionDays?.toString() ?? '';
    _gb.text = v.maxGb?.toString() ?? '';
  }

  Future<void> _load() async {
    try {
      final v = await widget.session.api!.fetchCallRecordingRetention();
      if (mounted) setState(() => _show(v));
    } catch (_) {
      // 예전 서버(이 API가 없음) — 칸을 그리지 않는다.
    }
  }

  int? _read(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : int.tryParse(t);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final v = await widget.session.api!.updateCallRecordingRetention(
        retentionDays: _read(_days),
        maxGb: _read(_gb),
      );
      if (!mounted) return;
      setState(() => _show(v));
      showAppToast(context, tr('녹화 보관 설정을 저장했습니다'));
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : e.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    if (view == null || !view.enabled) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    Widget field(TextEditingController c, String label, String suffix) =>
        SizedBox(
          width: 160,
          child: TextField(
            controller: c,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: label,
              suffixText: suffix,
              hintText: tr('제한 없음'),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );
    return Column(
      key: const ValueKey('admin-call-recordings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(height: 1),
        ),
        Text(tr('화상회의 녹화 보관'), style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(
          tr(
            '녹화 파일을 보관할 기간과 녹화 파일 전체 용량을 정하면, 넘는 만큼 오래된 녹화 파일부터 지웁니다(하루에 한 번, 새 녹화가 올라올 때). 대화방의 녹화 파일은 "삭제된 파일"로 바뀌고 회의록은 남습니다. 비우면 제한하지 않습니다.',
          ),
          style: hint,
        ),
        const SizedBox(height: 4),
        Text(
          tr('지금 녹화 파일 {n}개 · {size}{purged}', {
            'n': view.count,
            'size': formatFileSize(view.totalBytes),
            'purged': view.purgedCount > 0
                ? tr(' · 지금까지 지운 것 {n}개', {'n': view.purgedCount})
                : '',
          }),
          style: hint,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            field(_days, tr('보관 기간'), tr('일')),
            field(_gb, tr('전체 용량'), 'GB'),
            FilledButton.tonal(
              key: const ValueKey('admin-call-recordings-save'),
              onPressed: _saving ? null : _save,
              child: Text(tr('저장')),
            ),
          ],
        ),
      ],
    );
  }
}
