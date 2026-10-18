import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/retrying_network_image.dart';
import 'approval_forms.dart' show ApprovalDateField;
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;
import '../../l10n/tr.dart';

/// 내 결재 설정(서명·도장, 대결)과 관리 탭의 결재 통계.

// ── 서명·도장 ─────────────────────────────────────────────────────────────

/// 도장 글자 배치 — 이름(3자까지)에 '인'을 붙여 두 줄 두 칸에 오른쪽 위부터 세로로(전통 도장 모양). 4자가 넘는 이름은 한 줄로.
/// 칸 순서: [오른쪽 위, 오른쪽 아래, 왼쪽 위, 왼쪽 아래].
List<String> stampGlyphs(String name) {
  final chars = name.trim().characters.toList();
  if (chars.isEmpty) return [tr('인')];
  if (chars.length > 4) return [chars.join()];
  final glyphs = chars.length == 4 ? chars : [...chars, tr('인')];
  // 한 글자 이름 + 인이면 세로 두 칸, 두 글자 이름 + 인이면 오른쪽 둘·왼쪽 하나, 세 글자 이름 + 인(또는 네 글자)이면 네 칸.
  return glyphs;
}

/// 붉은 원 도장 그림(PNG) — [stampGlyphs] 배치.
Future<Uint8List> renderStampPng(String name, {double size = 240}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const red = Color(0xFFC62828);
  canvas.drawCircle(
    Offset(size / 2, size / 2),
    size / 2 - 8,
    Paint()
      ..color = red
      ..style = PaintingStyle.stroke
      ..strokeWidth = size / 22,
  );
  final glyphs = stampGlyphs(name);
  void draw(String text, Offset center, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: red,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          fontFamily: 'NanumBarunGothicYetHangul',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size * 0.8);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  final c = size / 2;
  final q = size * 0.2;
  if (glyphs.length == 1) {
    draw(
      glyphs[0],
      Offset(c, c),
      glyphs[0].characters.length > 4 ? size * 0.16 : size * 0.3,
    );
  } else if (glyphs.length == 2) {
    draw(glyphs[0], Offset(c, c - q), size * 0.32);
    draw(glyphs[1], Offset(c, c + q), size * 0.32);
  } else {
    final fs = size * 0.28;
    draw(glyphs[0], Offset(c + q, c - q), fs);
    draw(glyphs[1], Offset(c + q, c + q), fs);
    if (glyphs.length == 3) {
      draw(glyphs[2], Offset(c - q, c), fs);
    } else {
      draw(glyphs[2], Offset(c - q, c - q), fs);
      draw(glyphs[3], Offset(c - q, c + q), fs);
    }
  }
  final image = await recorder.endRecording().toImage(
    size.toInt(),
    size.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// "내 서명·도장" — 지금 서명을 보여 주고, 그리기·도장 만들기·그림 올리기·지우기. 승인할 때 그때의 서명이 결재란에 남는다.
Future<void> showSignatureDialog(
  BuildContext context, {
  required GroupwareApi api,
  required Session session,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SignatureDialog(api: api, session: session),
);

class _SignatureDialog extends StatefulWidget {
  final GroupwareApi api;
  final Session session;
  const _SignatureDialog({required this.api, required this.session});

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  String? _url;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.api
        .context()
        .then((ctx) {
          if (mounted) {
            setState(() => (_url = ctx.signatureUrl, _loaded = true));
          }
        })
        .catchError((_) {
          if (mounted) setState(() => _loaded = true);
        });
  }

  Future<void> _upload(Uint8List bytes, String name) async {
    setState(() => _busy = true);
    try {
      final up = await widget.session.api!.uploadFile(
        XFile.fromData(bytes, name: name, mimeType: 'image/png'),
      );
      final url = await widget.api.setSignature(up.url);
      if (mounted) {
        setState(() => _url = url);
        showAppToast(context, tr('서명을 정했습니다.'));
      }
    } catch (e) {
      if (mounted) showAppToast(context, tr('서명을 정하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _draw() async {
    final bytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => const SignaturePadDialog(),
    );
    if (bytes != null && mounted) await _upload(bytes, 'signature.png');
  }

  Future<void> _stamp() async {
    final name = widget.session.name ?? '';
    final bytes = await renderStampPng(name);
    if (mounted) await _upload(bytes, 'stamp.png');
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    final file = picked?.files.firstOrNull;
    if (file == null || (file.path == null && file.bytes == null)) return;
    setState(() => _busy = true);
    try {
      final up = await widget.session.api!.uploadFile(file.xFile);
      final url = await widget.api.setSignature(up.url);
      if (mounted) setState(() => _url = url);
    } catch (e) {
      if (mounted) showAppToast(context, tr('서명을 정하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      await widget.api.deleteSignature();
      if (mounted) setState(() => _url = null);
    } catch (e) {
      if (mounted) showAppToast(context, tr('지우지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('내 서명·도장')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                '결재를 승인하면 이 그림이 결재란에 들어갑니다(그때의 그림이 남아 나중에 바꿔도 지난 결재는 그대로). 없으면 "승인" 도장 글자로 보입니다.',
              ),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            const SizedBox(height: 12),
            Container(
              height: 110,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: !_loaded
                  ? const CircularProgressIndicator()
                  : _url == null
                  ? Text(
                      tr('정한 서명이 없습니다.'),
                      key: const ValueKey('signature-none'),
                      style: TextStyle(color: hint),
                    )
                  : RetryingNetworkImage(
                      key: const ValueKey('signature-current'),
                      imageUrl: widget.session.resolveUrl(_url!),
                      height: 96,
                      fit: BoxFit.contain,
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('signature-draw'),
                  onPressed: _busy ? null : _draw,
                  icon: const Icon(Icons.draw_outlined, size: 18),
                  label: Text(tr('그리기')),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('signature-stamp'),
                  onPressed: _busy ? null : _stamp,
                  icon: const Icon(Icons.approval_outlined, size: 18),
                  label: Text(tr('이름 도장 만들기')),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('signature-upload'),
                  onPressed: _busy ? null : _pickImage,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: Text(tr('그림 올리기')),
                ),
                if (_url != null)
                  TextButton(
                    key: const ValueKey('signature-clear'),
                    onPressed: _busy ? null : _clear,
                    child: Text(tr('지우기')),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

/// 서명 그리기 — 칸 안에 그린 획을 투명 배경 PNG로 돌려준다.
class SignaturePadDialog extends StatefulWidget {
  const SignaturePadDialog({super.key});

  @override
  State<SignaturePadDialog> createState() => _SignaturePadDialogState();
}

class _SignaturePadDialogState extends State<SignaturePadDialog> {
  final _strokes = <List<Offset>>[];
  static const _size = Size(320, 140);

  Future<void> _save() async {
    if (_strokes.every((s) => s.length < 2)) return;
    const scale = 2.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    _SignaturePainter(_strokes).paint(canvas, _size);
    final image = await recorder.endRecording().toImage(
      (_size.width * scale).toInt(),
      (_size.height * scale).toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (mounted && data != null) {
      Navigator.of(context).pop(data.buffer.asUint8List());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('서명 그리기')),
      content: Container(
        width: _size.width,
        height: _size.height,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          color: Colors.white,
        ),
        child: GestureDetector(
          key: const ValueKey('signature-pad'),
          onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
          onPanUpdate: (d) =>
              setState(() => _strokes.last.add(d.localPosition)),
          child: CustomPaint(painter: _SignaturePainter(_strokes), size: _size),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(_strokes.clear),
          child: Text(tr('다시 그리기')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('signature-pad-save'),
          onPressed: _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  _SignaturePainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final p in s.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}

// ── 대결 ─────────────────────────────────────────────────────────────────

/// "대결(부재) 설정" — 자리를 비우는 동안 내 차례 결재를 대신할 사람과 기간. 내가 맡은 대결도 함께 보인다.
Future<void> showDelegationsDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  required GroupwareChanges changes,
}) => showDialog<void>(
  context: context,
  builder: (_) => _DelegationsDialog(
    api: api,
    ctx: ctx,
    session: session,
    changes: changes,
  ),
);

class _DelegationsDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  final GroupwareChanges changes;
  const _DelegationsDialog({
    required this.api,
    required this.ctx,
    required this.session,
    required this.changes,
  });

  @override
  State<_DelegationsDialog> createState() => _DelegationsDialogState();
}

class _DelegationsDialogState extends State<_DelegationsDialog> {
  List<ApprovalDelegation>? _list;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.api.delegations();
      if (mounted) setState(() => _list = list);
    } catch (e) {
      if (mounted) showAppToast(context, tr('불러오지 못했습니다: {e}', {'e': e}));
    }
  }

  Future<void> _add() async {
    final candidates = await widget.api.candidates();
    if (!mounted) return;
    final input =
        await showDialog<
          ({String delegateId, String start, String end, String? reason})
        >(
          context: context,
          builder: (_) => _DelegationEditDialog(
            candidates: candidates,
            today: widget.ctx.today,
          ),
        );
    if (input == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.createDelegation(
        delegateId: input.delegateId,
        startDate: input.start,
        endDate: input.end,
        reason: input.reason,
      );
      await _load();
      widget.changes.bump();
      if (mounted) showAppToast(context, tr('대결을 맡겼습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(ApprovalDelegation d) async {
    setState(() => _busy = true);
    try {
      await widget.api.deleteDelegation(d.id);
      await _load();
      widget.changes.bump();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final me = widget.session.userId;
    final hint = Theme.of(context).hintColor;
    final mine = list?.where((d) => d.userId == me).toList() ?? const [];
    final toMe = list?.where((d) => d.delegateId == me).toList() ?? const [];
    String period(ApprovalDelegation d) =>
        '${d.startDate} ~ ${d.endDate}${d.activeOn(widget.ctx.today) ? tr(' · 지금 효력') : ''}${d.reason == null ? '' : ' · ${d.reason}'}';
    return AlertDialog(
      title: Text(tr('대결(부재) 설정')),
      content: SizedBox(
        width: 420,
        child: list == null
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    tr(
                      '자리를 비우는 동안 내 차례가 된 결재를 대신 승인·반려할 사람을 정합니다. 대신 한 결재에는 누가 했는지 함께 남습니다.',
                    ),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('내가 맡긴 대결'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (mine.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(tr('없음'), style: TextStyle(color: hint)),
                    ),
                  for (final d in mine)
                    ListTile(
                      key: ValueKey('delegation-${d.id}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        tr('{d.delegateName}님이 대신', {
                          'd.delegateName': d.delegateName,
                        }),
                      ),
                      subtitle: Text(period(d)),
                      trailing: IconButton(
                        tooltip: tr('거두기'),
                        icon: const Icon(Icons.close),
                        onPressed: _busy ? null : () => _remove(d),
                      ),
                    ),
                  if (toMe.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr('내가 맡은 대결'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    for (final d in toMe)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr('{d.userName}님 대신', {'d.userName': d.userName}),
                        ),
                        subtitle: Text(period(d)),
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
        FilledButton.icon(
          key: const ValueKey('delegation-add'),
          onPressed: _busy || list == null ? null : _add,
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('대결 맡기기')),
        ),
      ],
    );
  }
}

class _DelegationEditDialog extends StatefulWidget {
  final List<ApprovalCandidate> candidates;
  final String today;
  const _DelegationEditDialog({required this.candidates, required this.today});

  @override
  State<_DelegationEditDialog> createState() => _DelegationEditDialogState();
}

class _DelegationEditDialogState extends State<_DelegationEditDialog> {
  String? _delegateId;
  late String _start = widget.today;
  late String _end = widget.today;
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('대결 맡기기')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('delegation-delegate'),
              initialValue: _delegateId,
              decoration: InputDecoration(labelText: tr('대신 결재할 사람')),
              items: [
                for (final c in widget.candidates)
                  DropdownMenuItem(
                    value: c.id,
                    child: Text('${c.name} (${c.username})'),
                  ),
              ],
              onChanged: (v) => setState(() => _delegateId = v),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ApprovalDateField(
                  key: const ValueKey('delegation-start'),
                  label: tr('시작'),
                  value: _start,
                  onChanged: (v) => setState(() {
                    _start = v;
                    if (_end.compareTo(v) < 0) _end = v;
                  }),
                ),
                ApprovalDateField(
                  key: const ValueKey('delegation-end'),
                  label: tr('끝'),
                  value: _end,
                  onChanged: (v) => setState(() => _end = v),
                ),
              ],
            ),
            TextField(
              key: const ValueKey('delegation-reason'),
              controller: _reason,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: tr('사유(선택)'),
                hintText: tr('예: 출장, 휴가'),
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          key: const ValueKey('delegation-save'),
          onPressed: () {
            if (_delegateId == null) {
              return setState(() => _error = tr('대신 결재할 사람을 고르세요.'));
            }
            final reason = _reason.text.trim();
            Navigator.of(context).pop((
              delegateId: _delegateId!,
              start: _start,
              end: _end,
              reason: reason.isEmpty ? null : reason,
            ));
          },
          child: Text(tr('맡기기')),
        ),
      ],
    );
  }
}

// ── 결재 통계(관리 탭) ─────────────────────────────────────────────────────

/// 관리 탭의 "결재 통계" — 달마다(앞뒤로 넘김) 올린 결재의 종류별·결재자별 건수와 평균 처리 시간. [session]이 있으면 보고 있는 기간을
/// 엑셀(요약·결재자별·문서 세 시트 — 서버 GET /groupware/stats/export)로 받아 여는 단추도 보인다.
class ApprovalStatsSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;

  /// 엑셀 내려받기([Session.downloadAuthedFile])에 쓴다 — 없으면 내보내기 단추를 숨긴다.
  final Session? session;
  const ApprovalStatsSection({
    super.key,
    required this.api,
    required this.ctx,
    this.session,
  });

  @override
  State<ApprovalStatsSection> createState() => _ApprovalStatsSectionState();
}

class _ApprovalStatsSectionState extends State<ApprovalStatsSection> {
  late String _month = widget.ctx.today.substring(0, 7);
  ApprovalStats? _stats;
  String? _error;

  /// 엑셀을 받는 중 — 단추를 막고 돌아가는 표시.
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  (String, String) get _range {
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final last = DateTime(y, m + 1, 0).day;
    final end = '$_month-${last.toString().padLeft(2, '0')}';
    return (
      '$_month-01',
      end.compareTo(widget.ctx.today) > 0 ? widget.ctx.today : end,
    );
  }

  Future<void> _load() async {
    setState(() => (_stats = null, _error = null));
    try {
      final (from, to) = _range;
      final s = await widget.api.stats(from: from, to: to);
      if (mounted) setState(() => _stats = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _shift(int months) {
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final d = DateTime(y, m + months);
    final next = '${d.year}-${d.month.toString().padLeft(2, '0')}';
    if (next.compareTo(widget.ctx.today.substring(0, 7)) > 0) return;
    _month = next;
    _load();
  }

  /// 보고 있는 기간([_range] — 이번 달이면 오늘까지)을 엑셀로 받아 연다. 파일 이름은 근태 엑셀처럼
  /// "결재통계_{범위}_{시작}_{끝}.xlsx"(파일 이름에 못 쓰는 글자는 '_'). 이름은 내려받은 파일이라 옮기지 않는다.
  Future<void> _export() async {
    final session = widget.session;
    if (session == null) return;
    setState(() => _exporting = true);
    try {
      final (from, to) = _range;
      final name = '결재통계_${widget.ctx.scopeLabel}_${from}_$to.xlsx'.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final path = await session.downloadAuthedFile(
        widget.api.statsExportPath(from: from, to: to),
        fileName: name,
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final hint = Theme.of(context).hintColor;
    final small = TextStyle(fontSize: 12, color: hint);
    Widget cells(List<String> values, {bool head = false, Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          for (final (i, v) in values.indexed)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                v,
                style: head ? small : null,
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('결재 통계'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('이전 달'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(-1),
              ),
              Text(_month, key: const ValueKey('gw-stats-month')),
              IconButton(
                key: const ValueKey('gw-stats-next'),
                tooltip: tr('다음 달'),
                icon: const Icon(Icons.chevron_right),
                onPressed: _month == widget.ctx.today.substring(0, 7)
                    ? null
                    : () => _shift(1),
              ),
              if (widget.session != null)
                IconButton(
                  key: const ValueKey('gw-stats-export'),
                  tooltip: tr('엑셀로 내보내기'),
                  onPressed: _exporting ? null : _export,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _error != null
              ? Text(_error!)
              : s == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr(
                        '올린 결재 {s.totals.total}건 · 승인 {s.totals.approved} · 반려 {s.totals.rejected} · 진행 중 {s.totals.pending} · 끝날 때까지 평균 {p0}',
                        {
                          's.totals.total': s.totals.total,
                          's.totals.approved': s.totals.approved,
                          's.totals.rejected': s.totals.rejected,
                          's.totals.pending': s.totals.pending,
                          'p0': hoursText(s.totals.avgHours),
                        },
                      ),
                      key: const ValueKey('gw-stats-totals'),
                    ),
                    const SizedBox(height: 8),
                    cells([
                      tr('종류'),
                      tr('건수'),
                      tr('승인'),
                      tr('반려'),
                      tr('평균'),
                    ], head: true),
                    for (final k in s.byKind)
                      cells([
                        k.label,
                        '${k.total}',
                        '${k.approved}',
                        '${k.rejected}',
                        hoursText(k.avgHours),
                      ], key: ValueKey('gw-stats-kind-${k.label}')),
                    const SizedBox(height: 10),
                    cells([
                      tr('결재자'),
                      tr('결정'),
                      tr('반려'),
                      // 합의에서 반대 의견을 남긴 수(반려와 달리 결재는 계속된다).
                      tr('반대'),
                      tr('대결'),
                      tr('대기'),
                      tr('평균 응답'),
                    ], head: true),
                    for (final a in s.byApprover)
                      cells([
                        a.name,
                        '${a.decided}',
                        '${a.rejected}',
                        '${a.disagreed}',
                        '${a.proxied}',
                        '${a.waiting}',
                        hoursText(a.avgHours),
                      ], key: ValueKey('gw-stats-approver-${a.userId}')),
                    if (s.byKind.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(tr('이 달에 올린 결재가 없습니다.'), style: small),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

// ── 결재 전자서명(관리 탭) ─────────────────────────────────────────────────

/// 관리 탭의 "결재 전자서명" — 서버 서명 키(Ed25519)의 지문과 공개 키(PEM). 결재자가 승인·반려할 때마다 서버가 그 결정을 이 키로
/// 서명하고(server approvalSeal.js), 결재 문서의 "전자서명 검증"이 그 서명으로 바뀐 데가 있는지 본다. 관리 탭을 열 때마다 부르지 않게
/// 펼칠 때 한 번만 받는다(GET /groupware/seal-key). 못 받으면 그 까닭만 보이고, 접었다 다시 펼치면 다시 받는다.
class ApprovalSealKeySection extends StatefulWidget {
  final GroupwareApi api;
  const ApprovalSealKeySection({super.key, required this.api});

  @override
  State<ApprovalSealKeySection> createState() => _ApprovalSealKeySectionState();
}

class _ApprovalSealKeySectionState extends State<ApprovalSealKeySection> {
  ({String fingerprint, String publicKey})? _key;
  String? _error;
  bool _loading = false;

  Future<void> _load() async {
    if (_key != null || _loading) return;
    setState(() => (_loading = true, _error = null));
    try {
      final key = await widget.api.sealKey();
      if (mounted) setState(() => _key = key);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    final key = _key;
    if (key == null) return;
    await Clipboard.setData(ClipboardData(text: key.publicKey));
    if (mounted) showAppToast(context, tr('공개 키를 복사했습니다.'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = TextStyle(fontSize: 12, color: theme.hintColor);
    final key = _key;
    return ExpansionTile(
      key: const ValueKey('gw-seal-key'),
      leading: const Icon(Icons.verified_user_outlined),
      title: Text(tr('결재 전자서명')),
      onExpansionChanged: (open) {
        if (open) _load();
      },
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        Text(
          tr(
            '결재자가 승인·반려할 때마다 서버가 그 결정을 이 키로 서명합니다. 결재 문서의 "전자서명 검증"으로 내용·결정 기록·서명 그림이 바뀌었는지 볼 수 있습니다.',
          ),
          style: small,
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Text(
            tr('키를 불러오지 못했습니다: {e}', {'e': _error}),
            key: const ValueKey('gw-seal-key-error'),
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          )
        else if (key == null)
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          Text(tr('키 지문'), style: small),
          SelectableText(
            key.fingerprint,
            key: const ValueKey('gw-seal-key-fingerprint'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('gw-seal-key-copy'),
              onPressed: key.publicKey.isEmpty ? null : _copy,
              icon: const Icon(Icons.copy, size: 18),
              label: Text(tr('공개 키 복사')),
            ),
          ),
        ],
      ],
    );
  }
}
