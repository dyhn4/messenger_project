import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// 환경설정 > 화면 설정 > 글꼴(Windows 전용)에서 고른 글꼴과 **텍스트 크기**는 **허용 목록**에만
/// 입힌다 — 화면 영역을 통째로 감싸면(예전 방식) 단추·메뉴·전송 시간·도구모음 같은 것까지 다 바뀌어서,
/// 아래 곳의 글자 위젯 하나하나에만 직접 적용한다. 그 외는 모두 기본 글꼴·기본 크기 그대로다.
///
/// - 사이드바 채팅 목록의 방 이름(토픽방·그룹채팅방·채팅방) — desktop_home_screen.dart의
///   _RoomTile, room_list_screen.dart의 목록 줄
/// - 채팅 내용의 메시지 본문 — message_bubble.dart
/// - 채팅 내용의 댓글 본문 — message_comments_card.dart
///
/// 텍스트 크기는 [ChatFont]가 자식 위젯에 `MediaQuery.textScaler`를 얹어서 적용한다 — 글자 위젯 안의
/// 멘션 칩·링크 같은 자식 글자까지 한 번에 같은 배율로 커지고 작아진다(글꼴은 글자 style에 직접 얹는다).
///
/// 쓰는 법: 적용할 글자 위젯을 [ChatFont]로 감싸고, 받은 `font`를 그 글자의 원래 style에
/// [applyChatFont]로 얹는다. `Theme.of(context).textTheme.*` 스타일은 fontFamily("Roboto")가
/// 이미 박혀 있어서 바깥에서 DefaultTextStyle만 덮어써서는 안 바뀌므로, 이렇게 글자의 style에
/// 직접 얹어야 확실히 바뀐다.
class ChatFont extends StatelessWidget {
  final AppSettings settings;
  final Widget Function(BuildContext context, TextStyle? font) builder;
  const ChatFont({super.key, required this.settings, required this.builder});

  @override
  Widget build(BuildContext context) {
    // 저장하면 바로 다시 그린다(앱 전체 재빌드에 기대지 않는다).
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final child = builder(context, chatFontStyle(settings));
        // 100%면 건드리지 않는다(기기 설정의 글자 크기를 그대로 따른다).
        if (settings.textScale == 1.0) return child;
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(settings.textScale)),
          child: child,
        );
      },
    );
  }
}

/// 고른 글꼴의 스타일 — "시스템 기본"(빈 문자열)이면 null(아무 것도 안 바꾼다는 뜻). 옛한글
/// 폴백도 같이 실어서 어떤 글꼴을 고르든 옛한글이 깨지지 않게 한다.
TextStyle? chatFontStyle(AppSettings settings) {
  final family = settings.fontFamily;
  if (family.isEmpty) return null;
  return TextStyle(
    fontFamily: family,
    fontFamilyFallback: const [oldHangulFontFamily],
  );
}

/// [base](글자의 원래 style)에 [font]를 얹는다 — 색·크기·굵기 등은 그대로 두고 글꼴만 바뀐다.
/// [font]가 null이면(시스템 기본) [base]를 그대로 돌려준다.
TextStyle? applyChatFont(TextStyle? base, TextStyle? font) {
  if (font == null) return base;
  return (base ?? const TextStyle()).merge(font);
}
