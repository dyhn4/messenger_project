// 팀 공유 드라이브 모델(서버 drive.js·driveRules.js) — 폴더·파일·파일 판·휴지통.

DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

List<Map<String, dynamic>> _maps(Object? v) => [
  for (final e in (v as List? ?? const []))
    if (e is Map) e.cast<String, dynamic>(),
];

class DriveFolder {
  final String id;
  final String name;
  final String? parentId;
  final String? createdBy;
  final DateTime? updatedAt;

  /// 찾기·휴지통에서만 — 어느 폴더에 있는지("기획 / 2026").
  final String? path;
  final DateTime? deletedAt;

  const DriveFolder({
    required this.id,
    required this.name,
    this.parentId,
    this.createdBy,
    this.updatedAt,
    this.path,
    this.deletedAt,
  });

  factory DriveFolder.fromJson(Map<String, dynamic> j) => DriveFolder(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    parentId: j['parentId'] as String?,
    createdBy: j['createdBy'] as String?,
    updatedAt: _time(j['updatedAt']),
    // 찾기·휴지통은 글("기획 / 2026"), 파일 상세는 빵부스러기 목록(DriveFileDetail.path)이라 글일 때만.
    path: j['path'] is String ? j['path'] as String : null,
    deletedAt: _time(j['deletedAt']),
  );
}

class DriveFile {
  final String id;
  final String name;
  final String? folderId;
  final int version;
  final int? size;
  final String? mimeType;
  final String? createdBy;
  final DateTime? updatedAt;
  final String? updatedByName;

  /// 서명된 내려받기 링크(/files/…) — 휴지통에서는 null.
  final String? url;
  final String? path;
  final DateTime? deletedAt;

  const DriveFile({
    required this.id,
    required this.name,
    this.folderId,
    this.version = 1,
    this.size,
    this.mimeType,
    this.createdBy,
    this.updatedAt,
    this.updatedByName,
    this.url,
    this.path,
    this.deletedAt,
  });

  factory DriveFile.fromJson(Map<String, dynamic> j) => DriveFile(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    folderId: j['folderId'] as String?,
    version: (j['version'] as num?)?.toInt() ?? 1,
    size: (j['size'] as num?)?.toInt(),
    mimeType: j['mimeType'] as String?,
    createdBy: j['createdBy'] as String?,
    updatedAt: _time(j['updatedAt']),
    updatedByName: j['updatedByName'] as String?,
    url: j['url'] as String?,
    // 찾기·휴지통은 글("기획 / 2026"), 파일 상세는 빵부스러기 목록(DriveFileDetail.path)이라 글일 때만.
    path: j['path'] is String ? j['path'] as String : null,
    deletedAt: _time(j['deletedAt']),
  );
}

/// 폴더 하나의 내용.
class DriveListing {
  final DriveFolder? folder;
  final List<({String id, String name})> path;
  final List<DriveFolder> folders;
  final List<DriveFile> files;
  final bool canWrite;
  final bool isManager;
  final int usageBytes;

  const DriveListing({
    this.folder,
    this.path = const [],
    this.folders = const [],
    this.files = const [],
    this.canWrite = false,
    this.isManager = false,
    this.usageBytes = 0,
  });

  factory DriveListing.fromJson(Map<String, dynamic> j) => DriveListing(
    folder: j['folder'] is Map
        ? DriveFolder.fromJson((j['folder'] as Map).cast<String, dynamic>())
        : null,
    path: [
      for (final p in _maps(j['path']))
        (id: p['id'] as String, name: p['name'] as String? ?? ''),
    ],
    folders: [for (final f in _maps(j['folders'])) DriveFolder.fromJson(f)],
    files: [for (final f in _maps(j['files'])) DriveFile.fromJson(f)],
    canWrite: j['canWrite'] as bool? ?? false,
    isManager: j['isManager'] as bool? ?? false,
    usageBytes: (j['usageBytes'] as num?)?.toInt() ?? 0,
  );
}

class DriveVersion {
  final int version;
  final int? size;
  final String uploaderName;
  final String? note;
  final DateTime? createdAt;
  final String? url;

  const DriveVersion({
    required this.version,
    this.size,
    required this.uploaderName,
    this.note,
    this.createdAt,
    this.url,
  });

  factory DriveVersion.fromJson(Map<String, dynamic> j) => DriveVersion(
    version: (j['version'] as num).toInt(),
    size: (j['size'] as num?)?.toInt(),
    uploaderName: j['uploaderName'] as String? ?? '',
    note: j['note'] as String?,
    createdAt: _time(j['createdAt']),
    url: j['url'] as String?,
  );
}

/// 파일 하나와 판 기록.
class DriveFileDetail {
  final DriveFile file;
  final List<({String id, String name})> path;
  final List<DriveVersion> versions;
  final bool canRemove;
  final bool canWrite;

  const DriveFileDetail({
    required this.file,
    this.path = const [],
    this.versions = const [],
    this.canRemove = false,
    this.canWrite = false,
  });

  factory DriveFileDetail.fromJson(Map<String, dynamic> j) => DriveFileDetail(
    file: DriveFile.fromJson(j),
    path: [
      for (final p in _maps(j['path']))
        (id: p['id'] as String, name: p['name'] as String? ?? ''),
    ],
    versions: [for (final v in _maps(j['versions'])) DriveVersion.fromJson(v)],
    canRemove: j['canRemove'] as bool? ?? false,
    canWrite: j['canWrite'] as bool? ?? false,
  );
}

class DriveTrash {
  final List<DriveFolder> folders;
  final List<DriveFile> files;
  final bool isManager;
  const DriveTrash({
    this.folders = const [],
    this.files = const [],
    this.isManager = false,
  });

  factory DriveTrash.fromJson(Map<String, dynamic> j) => DriveTrash(
    folders: [for (final f in _maps(j['folders'])) DriveFolder.fromJson(f)],
    files: [for (final f in _maps(j['files'])) DriveFile.fromJson(f)],
    isManager: j['isManager'] as bool? ?? false,
  );
}

/// 바이트 → "1.2MB"·"350KB"·"12B".
String formatBytes(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
}

/// 이름 겹침은 대소문자를 가리지 않는다(서버 driveRules.js nameKey와 같게).
String driveNameKey(String name) => name.toLowerCase();
