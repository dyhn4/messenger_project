/// 조직도(부서 트리와 상위자) — 서버 orgTree.js GET /org-tree의 모양. 범위는 부서·직책 설정을 따른다(계정 단위면 회사 하나 'server',
/// 팀 단위면 팀마다).
library;

import 'app_user.dart';

class OrgDepartment {
  final String id;
  final String? parentId;
  final String name;

  /// 부서장 — 그 부서 사람의 기본 상위자(본인이 부서장이면 위 부서의 부서장).
  final String? headId;
  final int sortOrder;

  const OrgDepartment({
    required this.id,
    this.parentId,
    required this.name,
    this.headId,
    this.sortOrder = 0,
  });

  factory OrgDepartment.fromJson(Map<String, dynamic> json) => OrgDepartment(
    id: json['id'] as String,
    parentId: json['parentId'] as String?,
    name: json['name'] as String? ?? '',
    headId: json['headId'] as String?,
    sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
  );
}

class OrgMember {
  final String id;
  final String name;

  /// 아이디 — 서버 전체를 보는 사람·팀을 같이 쓰는 사람에게만 온다(그 밖에는 null).
  final String? username;
  final String? role;
  final String avatarType;
  final String? avatarEmoji;
  final String? avatarColor;
  final String? avatarUrl;
  final String? position;
  final String? departmentId;

  /// 따로 정한 상위자(없으면 null — 부서장이 상위자).
  final String? managerId;

  /// 실제 상위자 — 따로 정한 사람, 없으면 부서장(위로 올라가며 첫 부서장). 맨 위면 null.
  final String? effectiveManagerId;

  const OrgMember({
    required this.id,
    required this.name,
    this.username,
    this.role,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
    this.position,
    this.departmentId,
    this.managerId,
    this.effectiveManagerId,
  });

  factory OrgMember.fromJson(Map<String, dynamic> json) => OrgMember(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    username: json['username'] as String?,
    role: json['role'] as String?,
    avatarType: json['avatarType'] as String? ?? 'initial',
    avatarEmoji: json['avatarEmoji'] as String?,
    avatarColor: json['avatarColor'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    position: json['position'] as String?,
    departmentId: json['departmentId'] as String?,
    managerId: json['managerId'] as String?,
    effectiveManagerId: json['effectiveManagerId'] as String?,
  );

  /// 프로필 카드·아바타에 넘길 모양 — 아이디를 모르면 빈 글자.
  AppUser toAppUser({String? department}) => AppUser(
    id: id,
    username: username ?? '',
    name: name,
    avatarType: avatarType,
    avatarEmoji: avatarEmoji,
    avatarColor: avatarColor,
    avatarUrl: avatarUrl,
    role: role,
    department: department,
    position: position,
  );
}

class OrgTree {
  /// 'server'(회사 하나) | 'team'(팀마다).
  final String scope;
  final String scopeKey;
  final String? teamId;
  final String? teamName;
  final bool canEdit;
  final List<OrgDepartment> departments;
  final List<OrgMember> members;

  OrgTree({
    required this.scope,
    required this.scopeKey,
    this.teamId,
    this.teamName,
    this.canEdit = false,
    this.departments = const [],
    this.members = const [],
  });

  factory OrgTree.fromJson(Map<String, dynamic> json) => OrgTree(
    scope: json['scope'] as String? ?? 'server',
    scopeKey: json['scopeKey'] as String? ?? 'server',
    teamId: json['teamId'] as String?,
    teamName: json['teamName'] as String?,
    canEdit: json['canEdit'] == true,
    departments: [
      for (final d in json['departments'] as List? ?? const [])
        OrgDepartment.fromJson((d as Map).cast<String, dynamic>()),
    ],
    members: [
      for (final m in json['members'] as List? ?? const [])
        OrgMember.fromJson((m as Map).cast<String, dynamic>()),
    ],
  );

  late final Map<String, OrgDepartment> _departmentsById = {
    for (final d in departments) d.id: d,
  };
  late final Map<String, OrgMember> _membersById = {
    for (final m in members) m.id: m,
  };

  OrgDepartment? department(String? id) =>
      id == null ? null : _departmentsById[id];
  OrgMember? member(String? id) => id == null ? null : _membersById[id];

  /// [parentId] 바로 아래 부서들(null이면 맨 위) — 서버가 준 순서(순서 → 이름) 그대로.
  List<OrgDepartment> childrenOf(String? parentId) => [
    for (final d in departments)
      if (d.parentId == parentId ||
          (parentId == null &&
              d.parentId != null &&
              !_departmentsById.containsKey(d.parentId)))
        d,
  ];

  /// [departmentId] 부서 사람들 — 부서장이 먼저, 그다음 이름순(서버 순서).
  List<OrgMember> membersOf(String? departmentId) {
    final head = department(departmentId)?.headId;
    final list = [
      for (final m in members)
        if (departmentId == null
            ? (m.departmentId == null ||
                  !_departmentsById.containsKey(m.departmentId))
            : m.departmentId == departmentId)
          m,
    ];
    list.sort((a, b) => (a.id == head ? 0 : 1) - (b.id == head ? 0 : 1));
    return list;
  }

  /// [id] 아래 모든 부서 id(자기 빼고).
  Set<String> descendantsOf(String id) {
    final out = <String>{};
    final stack = [for (final c in childrenOf(id)) c.id];
    while (stack.isNotEmpty) {
      final next = stack.removeLast();
      if (!out.add(next)) continue;
      stack.addAll(childrenOf(next).map((c) => c.id));
    }
    return out;
  }

  /// [id] 부서와 그 아래 부서 사람 수.
  int headcount(String id) {
    final ids = {id, ...descendantsOf(id)};
    return members.where((m) => ids.contains(m.departmentId)).length;
  }

  /// "대표실 › 영업본부 › 영업1팀".
  String pathOf(String id) {
    final names = <String>[];
    final seen = <String>{};
    String? cur = id;
    while (cur != null && seen.add(cur)) {
      final d = _departmentsById[cur];
      if (d == null) break;
      names.add(d.name);
      cur = d.parentId;
    }
    return names.reversed.join(' › ');
  }

  /// 트리 순서(위에서부터, 깊이와 함께) — 부서 고르기 목록에.
  List<({OrgDepartment department, int depth})> flatten() {
    final out = <({OrgDepartment department, int depth})>[];
    final seen = <String>{};
    void walk(String? parentId, int depth) {
      for (final d in childrenOf(parentId)) {
        if (!seen.add(d.id)) continue;
        out.add((department: d, depth: depth));
        walk(d.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }
}
