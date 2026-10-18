import 'package:flutter/material.dart';

import '../models/favorite.dart';
import '../models/message.dart';
import '../services/session.dart';
import 'app_toast.dart';
import '../l10n/tr.dart';

/// 메시지·댓글의 "즐겨찾기 / 즐겨찾기 해제" — message_actions.dart의 더보기 메뉴(PC)와 롱프레스 시트(모바일)가
/// 같은 동작을 쓰도록 한곳에 모았다. 비밀 대화(서버가 내용을 몰라 목록에 못 보여 준다)·시스템 메시지·투표(카드 ⋯ 메뉴에
/// 자기 즐겨찾기가 있다)는 항목 자체를 뺀다.
bool canFavoriteEntry(
  Session session,
  Message message, {
  required bool isComment,
}) {
  final room = session.roomById(message.roomId);
  if (room != null && room.isSecret) return false;
  if (message.deleted) return false;
  if (isComment) return true;
  return message.type != MessageType.system && !message.isPoll;
}

/// 지금 즐겨찾기 상태인지 — 메뉴 문구를 정한다.
bool isEntryFavorite(Session session, String id, {required bool isComment}) =>
    isComment
    ? session.favorites.isCommentFavorite(id)
    : session.favorites.isMessageFavorite(id);

/// 즐겨찾기를 켜고 끈 뒤 토스트로 알린다(서버가 거절하면 그 문구).
Future<void> toggleEntryFavorite(
  BuildContext context,
  Session session,
  String id, {
  required bool isComment,
}) async {
  final next = !isEntryFavorite(session, id, isComment: isComment);
  try {
    await session.favorites.setFavorite(
      isComment ? FavoriteKind.comment : FavoriteKind.message,
      id,
      next,
    );
    if (context.mounted) {
      showAppToast(context, next ? tr('즐겨찾기에 담았습니다.') : tr('즐겨찾기에서 뺐습니다.'));
    }
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, tr('즐겨찾기를 바꾸지 못했습니다: {e}', {'e': e}));
    }
  }
}

/// 멤버 즐겨찾기 별 — 프로필 카드 머리에 얹는다. [teamId]는 어느 팀의 즐겨찾기인지(목록이 팀 단위다).
/// 나 자신에게는 그리지 않는다.
class MemberFavoriteStar extends StatelessWidget {
  final Session session;
  final String userId;
  final String teamId;
  const MemberFavoriteStar({
    super.key,
    required this.session,
    required this.userId,
    required this.teamId,
  });

  @override
  Widget build(BuildContext context) {
    if (userId == session.userId) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: session.favorites,
      builder: (context, _) {
        final on = session.favorites.isMemberFavorite(teamId, userId);
        return IconButton(
          key: const ValueKey('member-favorite-star'),
          icon: Icon(
            on ? Icons.star : Icons.star_border,
            color: on ? Colors.amber : Theme.of(context).hintColor,
          ),
          tooltip: on ? tr('즐겨찾기 해제') : tr('즐겨찾기'),
          onPressed: () async {
            try {
              await session.favorites.setFavorite(
                FavoriteKind.member,
                userId,
                !on,
                teamId: teamId,
              );
            } catch (e) {
              if (context.mounted) {
                showAppToast(context, tr('즐겨찾기를 바꾸지 못했습니다: {e}', {'e': e}));
              }
            }
          },
        );
      },
    );
  }
}
