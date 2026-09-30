import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/calendar.dart';
import '../../../services/calendar_controller.dart';
import '../../../widgets/app_toast.dart';
import '../calendar_common.dart';
import 'calendar_management_common.dart';

/// 검색어를 멈추고 이만큼 지나면 서버에 묻는다(글자마다 요청하지 않게).
const kCalendarSearchDebounce = Duration(milliseconds: 300);

/// "구독 캘린더" 옆 + — 다른 사람의 기본 캘린더나 공개된 공유 캘린더를 이름으로 찾아 구독한다.
Future<void> showCalendarSubscribe(
  BuildContext context,
  CalendarController controller,
) {
  return showCalendarSheet<void>(
    context,
    title: '구독할 캘린더 찾기',
    child: CalendarSubscribeView(controller: controller),
  );
}

/// 구독 검색 본문 — 검색 칸(디바운스) + 결과 목록. 열자마자 빈 검색으로 구독할 수 있는 캘린더를 보여 준다.
/// 비공개라 볼 수 없는 캘린더와 이미 내 것인 캘린더는 서버가 미리 걸러 준다.
class CalendarSubscribeView extends StatefulWidget {
  final CalendarController controller;
  final Duration debounce;
  const CalendarSubscribeView({
    super.key,
    required this.controller,
    this.debounce = kCalendarSearchDebounce,
  });

  @override
  State<CalendarSubscribeView> createState() => _CalendarSubscribeViewState();
}

class _CalendarSubscribeViewState extends State<CalendarSubscribeView> {
  final _query = TextEditingController();
  Timer? _timer;

  /// 늦게 도착한 옛 검색 응답을 버리려고 검색마다 올린다.
  int _seq = 0;
  List<CalendarSearchResult>? _results;
  String? _error;
  bool _loading = true;

  /// 구독 요청 중인 캘린더 id.
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _timer?.cancel();
    setState(() => _loading = true);
    _timer = Timer(widget.debounce, _search);
  }

  Future<void> _search() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.controller.searchCalendars(_query.text.trim());
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = null;
        _loading = false;
        _error = calendarErrorText(e, '검색하지 못했습니다. 잠시 후 다시 시도하세요.');
      });
    }
  }

  Future<void> _subscribe(CalendarSearchResult r) async {
    if (_pending.contains(r.id)) return;
    setState(() => _pending.add(r.id));
    try {
      await widget.controller.subscribe(r.id);
      if (!mounted) return;
      setState(() {
        _results = [
          for (final x in _results ?? const <CalendarSearchResult>[])
            if (x.id == r.id)
              CalendarSearchResult(
                id: x.id,
                kind: x.kind,
                name: x.name,
                color: x.color,
                ownerName: x.ownerName,
                subscribed: true,
              )
            else
              x,
        ];
      });
      showAppToast(context, "'${r.name}' 캘린더를 구독했습니다.");
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          calendarErrorText(e, '구독하지 못했습니다. 잠시 후 다시 시도하세요.'),
        );
      }
    } finally {
      if (mounted) setState(() => _pending.remove(r.id));
    }
  }

  static String _kindLabel(CalendarSearchResult r) {
    if (r.kind == 'personal') return '기본 캘린더';
    return r.ownerName == null ? '공유 캘린더' : '공유 캘린더 · 소유자 ${r.ownerName}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('cal-subscribe-search'),
          controller: _query,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            hintText: '캘린더 이름으로 검색',
            prefixIcon: Icon(Icons.search, size: 20),
            border: OutlineInputBorder(),
          ),
          onChanged: _onChanged,
          onSubmitted: (_) {
            _timer?.cancel();
            _search();
          },
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 2,
          child: _loading ? const LinearProgressIndicator() : null,
        ),
        const SizedBox(height: 8),
        Flexible(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _error!,
          key: const ValueKey('cal-subscribe-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    final results = _results;
    if (results == null) return const SizedBox(height: 120);
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            _query.text.trim().isEmpty ? '구독할 수 있는 캘린더가 없습니다.' : '검색 결과가 없습니다.',
            style: TextStyle(color: theme.hintColor),
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: results.length,
      itemBuilder: (context, i) {
        final r = results[i];
        return ListTile(
          key: ValueKey('cal-result-${r.id}'),
          contentPadding: EdgeInsets.zero,
          leading: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: calendarColor(r.color),
              shape: BoxShape.circle,
            ),
          ),
          minLeadingWidth: 14,
          title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_kindLabel(r)),
          trailing: r.subscribed
              ? Text(
                  '구독 중',
                  key: ValueKey('cal-subscribed-${r.id}'),
                  style: TextStyle(color: theme.hintColor),
                )
              : FilledButton.tonal(
                  key: ValueKey('cal-subscribe-${r.id}'),
                  onPressed: _pending.contains(r.id)
                      ? null
                      : () => _subscribe(r),
                  child: const Text('구독하기'),
                ),
        );
      },
    );
  }
}
