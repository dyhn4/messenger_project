import 'package:flutter/material.dart';

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

String _formatDate(DateTime date) =>
    '${date.year}년 ${date.month}월 ${date.day}일 ${_weekdays[date.weekday - 1]}요일';

/// 채팅 목록에서 날짜가 바뀔 때 가운데에 보여주는 구분선: 얇은 선 위에 날짜 텍스트를 겹쳐서
/// 선을 끊어 보이게 하는 흔한 "divider with label" 스타일. intl 로케일 데이터 초기화가
/// 필요 없도록 요일을 직접 매핑한다.
class DateDivider extends StatelessWidget {
  final DateTime date;

  /// 꺽쇠를 누르면 호출된다 — FloatingDatePill의 꺽쇠와 동일하게, 이 날짜를 기준으로 달력을
  /// 연다(chat_panel.dart의 _openDatePickerFor 참고). null이면(안 씀) 그냥 장식용 꺽쇠.
  final VoidCallback? onPickDate;
  const DateDivider({super.key, required this.date, this.onPickDate});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Divider(),
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onPickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatDate(date),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 16,
                      color: Theme.of(context).hintColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 스크롤 중 화면 상단에 잠깐 떴다 사라지는 "지금 보고 있는 날짜" 토스트. 오른쪽 꺽쇠를
/// 누르면(onPickDate) 달력을 열어 원하는 날짜로 바로 이동할 수 있다(chat_panel.dart의
/// _showDatePicker/DatePickerPopup 참고).
class FloatingDatePill extends StatelessWidget {
  final DateTime date;
  final VoidCallback? onPickDate;
  const FloatingDatePill({super.key, required this.date, this.onPickDate});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(14),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPickDate,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatDate(date),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down,
                size: 16,
                color: Theme.of(context).hintColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
