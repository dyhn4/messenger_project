import 'package:flutter/material.dart';

import '../services/api_client.dart' show PositionOption;
import 'role_badge.dart';

/// "직책 배지"를 보여줄지 — [label]의 서열이 '조장' 이상이면 true. PositionOption 목록은
/// 서버가 sortOrder 오름차순으로 이미 정렬해서 주므로(server/src/db/queries/positionOptions.js),
/// 배열 인덱스 자체가 서열이다(org_chart_screen.dart의 _positionRank와 같은 방식 — 인덱스가
/// 클수록 서열이 높음). '조장'이 관리자가 등록한 직책 목록에 없으면(이름을 바꿨거나 아직 안
/// 만듦) 안전하게 배지를 안 보여준다. desktop_home_screen.dart(PC)와 room_list_screen.dart/
/// chat_screen.dart(안드로이드)가 같이 쓴다.
bool hasLeadOrHigherPosition(List<PositionOption>? options, String? label) {
  if (options == null || label == null || label.isEmpty) return false;
  final leadIndex = options.indexWhere((o) => o.label == '조장');
  if (leadIndex == -1) return false;
  final index = options.indexWhere((o) => o.label == label);
  return index != -1 && index >= leadIndex;
}

/// 1:1 채팅 목록/상단에서 상대의 직책을 보여주는 작은 알약 배지 — role_badge.dart의
/// RoleBadge(관리자 콘솔 "회원"/"멤버" 탭에서 쓰는 것과 같은 모양)를 그대로 재사용한다.
class PositionBadge extends StatelessWidget {
  final String label;
  const PositionBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = dark
        ? (bg: const Color(0xFF1E3A4A), fg: const Color(0xFF7FC4E8))
        : (bg: const Color(0xFFE5F2FA), fg: const Color(0xFF1A6E9E));
    return RoleBadge(label: label, bg: colors.bg, fg: colors.fg);
  }
}
