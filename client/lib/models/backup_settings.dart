/// 관리자 콘솔 "백업" 탭 — 서버 전체 백업의 설정·상태·목록(server/src/admin.js GET /api/admin/backup, 백업은
/// server/src/backup.js). 백업 암호는 서버가 다시 내려주지 않아 정했는지([passwordConfigured])만 있다.
class BackupSettings {
  final bool enabled;

  /// 매일 몇 시에 백업하는지(0~23, 서버 PC 시각).
  final int hour;

  /// 최근 몇 개를 남기는지 — 이 PC와 외부 위치 둘 다.
  final int keep;
  final int keepMin;
  final int keepMax;
  final int passwordMin;

  /// 외부 백업 위치(NAS·외장 드라이브) — 정하지 않았으면 null.
  final String? destination;
  final bool passwordConfigured;

  /// 저장된 암호를 못 읽을 때(DB 암호화 키가 바뀐 채 DB만 복원한 경우 등) 그 이유.
  final String? passwordError;

  /// 서버 PC 안의 백업 폴더 경로.
  final String localDir;

  /// 이 관리자 콘솔을 서버 PC에서 열었는지 — NAS 경로(\\…)는 이때만 정할 수 있다.
  final bool fromServerPc;
  final BackupRun run;
  final BackupStatus status;
  final DateTime? nextRunAt;
  final List<String> warnings;
  final List<BackupEntry> backups;

  const BackupSettings({
    required this.enabled,
    required this.hour,
    required this.keep,
    required this.keepMin,
    required this.keepMax,
    required this.passwordMin,
    required this.destination,
    required this.passwordConfigured,
    required this.passwordError,
    required this.localDir,
    required this.fromServerPc,
    required this.run,
    required this.status,
    required this.nextRunAt,
    required this.warnings,
    required this.backups,
  });

  factory BackupSettings.fromJson(Map<String, dynamic> json) => BackupSettings(
    enabled: json['enabled'] as bool? ?? true,
    hour: (json['hour'] as num?)?.toInt() ?? 3,
    keep: (json['keep'] as num?)?.toInt() ?? 14,
    keepMin: (json['keepMin'] as num?)?.toInt() ?? 3,
    keepMax: (json['keepMax'] as num?)?.toInt() ?? 60,
    passwordMin: (json['passwordMin'] as num?)?.toInt() ?? 8,
    destination: json['destination'] as String?,
    passwordConfigured: json['passwordConfigured'] as bool? ?? false,
    passwordError: json['passwordError'] as String?,
    localDir: json['localDir'] as String? ?? '',
    fromServerPc: json['fromServerPc'] as bool? ?? false,
    run: BackupRun.fromJson(_map(json['run'])),
    status: BackupStatus.fromJson(_map(json['status'])),
    nextRunAt: _time(json['nextRunAt']),
    warnings: (json['warnings'] as List?)?.cast<String>() ?? const [],
    backups: [
      for (final b in (json['backups'] as List?) ?? const [])
        BackupEntry.fromJson(_map(b)),
    ],
  );
}

/// 지금 돌고 있는 백업 — [elsewhere]면 서버 PC의 시작 메뉴 "백업"이 돌리고 있다.
class BackupRun {
  final bool running;
  final bool elsewhere;
  final String? kind;
  final String? phase;
  final int? done;
  final int? total;

  const BackupRun({
    this.running = false,
    this.elsewhere = false,
    this.kind,
    this.phase,
    this.done,
    this.total,
  });

  factory BackupRun.fromJson(Map<String, dynamic> json) {
    final progress = _map(json['progress']);
    return BackupRun(
      running: json['running'] as bool? ?? false,
      elsewhere: json['elsewhere'] as bool? ?? false,
      kind: json['kind'] as String?,
      phase: json['phase'] as String?,
      done: (progress['done'] as num?)?.toInt(),
      total: (progress['total'] as num?)?.toInt(),
    );
  }

  bool get busy => running || elsewhere;
}

/// 마지막 백업 결과(서버의 backup-status.json — 시작 메뉴 "백업"이 한 것도 들어 있다).
class BackupStatus {
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;

  /// 'ok' | 'partial'(이 PC에는 했지만 외부 위치 실패) | 'failed' | null(아직 없음).
  final String? result;
  final String? error;
  final String? lastBackupName;
  final int? lastBackupBytes;
  final BackupExternal? external;

  const BackupStatus({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.result,
    this.error,
    this.lastBackupName,
    this.lastBackupBytes,
    this.external,
  });

  factory BackupStatus.fromJson(Map<String, dynamic> json) {
    final last = _map(json['lastBackup']);
    final external = json['external'];
    return BackupStatus(
      lastAttemptAt: _time(json['lastAttemptAt']),
      lastSuccessAt: _time(json['lastSuccessAt']),
      result: json['result'] as String?,
      error: json['error'] as String?,
      lastBackupName: last['name'] as String?,
      lastBackupBytes: (last['bytes'] as num?)?.toInt(),
      external: external is Map
          ? BackupExternal.fromJson(external.cast<String, dynamic>())
          : null,
    );
  }
}

/// 외부 위치로 마지막 복사한 결과.
class BackupExternal {
  final String? path;
  final bool ok;
  final String? error;
  final DateTime? lastOkAt;
  final int? uploadsTotal;
  final int? uploadsCopied;
  final int? uploadsBytes;

  const BackupExternal({
    this.path,
    this.ok = false,
    this.error,
    this.lastOkAt,
    this.uploadsTotal,
    this.uploadsCopied,
    this.uploadsBytes,
  });

  factory BackupExternal.fromJson(Map<String, dynamic> json) {
    final uploads = _map(json['uploads']);
    return BackupExternal(
      path: json['path'] as String?,
      ok: json['ok'] as bool? ?? false,
      error: json['error'] as String?,
      lastOkAt: _time(json['lastOkAt']),
      uploadsTotal: (uploads['total'] as num?)?.toInt(),
      uploadsCopied: (uploads['copied'] as num?)?.toInt(),
      uploadsBytes: (uploads['bytes'] as num?)?.toInt(),
    );
  }
}

/// 서버 PC 백업 폴더의 백업 하나.
class BackupEntry {
  final String name;
  final DateTime? createdAt;

  /// 'scheduled'(자동) | 'manual'(지금 백업·시작 메뉴).
  final String? kind;
  final int bytes;

  const BackupEntry({
    required this.name,
    this.createdAt,
    this.kind,
    this.bytes = 0,
  });

  factory BackupEntry.fromJson(Map<String, dynamic> json) => BackupEntry(
    name: json['name'] as String? ?? '',
    createdAt: _time(json['createdAt']),
    kind: json['kind'] as String?,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

DateTime? _time(Object? ms) =>
    ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
