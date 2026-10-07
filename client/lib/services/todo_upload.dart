import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/todo.dart';
import '../widgets/app_toast.dart';
import 'app_platform.dart';
import 'session.dart';

/// 한 메시지에 담는 첨부 수 — 더 많으면 나눠 보낸다(채팅 입력칸과 같다).
const todoUploadFilesPerMessage = 10;

/// 할 일 더보기(⋯ · •••)의 "파일 업로드" — 파일을 골라 결과물을 올린다.
/// - 할 일에 업로드 경로([Todo.uploadPath])가 있으면 그 폴더로 복사한다(PC에서만 — 그 PC에서 보이는 폴더·공유 폴더). 같은
///   이름이 있으면 `이름_보낸 사람.확장자`로 올린다([uniqueTargetPath]).
/// - 없으면 할 일을 만든 사람에게 1:1 메시지로 보낸다(내가 만든 할 일이거나 만든 사람이 없으면 나와의 대화로).
Future<void> uploadTodoFiles(
  BuildContext context,
  Session session,
  Todo todo,
) async {
  // 알림을 띄울 자리 — 고르는 동안 할 일 화면이 닫혀도 앱 맨 위에 뜨게 먼저 잡아 둔다.
  final overlay = Overlay.of(context, rootOverlay: true);
  void toast(String message) => showAppToastOnOverlay(overlay, message);

  final folder = todo.uploadPath;
  if (folder != null) {
    if (!AppPlatform.isWindows) {
      toast('지정된 업로드 경로로는 PC(Windows)에서만 올릴 수 있습니다.');
      return;
    }
    // 폴더를 건드리기(존재 확인·복사) 전에 — 열면 안 되는 서버(공인 IP·숫자로 꾸민 IP·WebDAV·장치 경로)면 거절하고,
    // 공유 폴더면 서버 이름을 보여 주며 한 번 물어본다(이 검사 전에 저장된 경로까지 막는다 — 검토 S32).
    final unsafe = remoteFolderError(folder);
    if (unsafe != null) {
      toast(unsafe);
      return;
    }
    if (!await confirmRemoteFolderAccess(context, folder)) return;
    if (!await Directory(folder).exists()) {
      toast('업로드 경로를 찾을 수 없습니다: $folder');
      return;
    }
  }

  final picked = await FilePicker.pickFiles(
    allowMultiple: true,
    dialogTitle: folder == null ? '보낼 파일 선택' : '업로드할 파일 선택',
  );
  final files = <XFile>[
    for (final f in picked?.files ?? const <PlatformFile>[])
      // 웹은 경로 없이 바이트만 온다 — xFile이 둘 다 감싼다.
      if (f.path != null || f.bytes != null) f.xFile,
  ];
  if (files.isEmpty) return;

  if (folder != null) {
    // 업로드 경로는 Windows에서만 쓰므로(위에서 걸렀다) 고른 파일에는 늘 경로가 있다.
    final result = await copyFilesToFolder(
      [for (final f in files) File(f.path)],
      folder,
      senderName: session.name ?? '',
    );
    toast(
      result.failed == 0
          ? '파일 ${result.copied}개를 업로드 경로에 올렸습니다.'
          : '파일 ${result.copied}개를 올렸고 ${result.failed}개는 올리지 못했습니다.',
    );
    return;
  }

  try {
    final room = await _uploadTargetRoom(session, todo);
    toast('파일 ${files.length}개를 보내는 중입니다...');
    final uploaded = await session.uploadAttachments(files);
    final controller = session.controllerFor(room);
    for (var i = 0; i < uploaded.length; i += todoUploadFilesPerMessage) {
      final end = (i + todoUploadFilesPerMessage).clamp(0, uploaded.length);
      await controller.sendUploadedAttachments(
        uploaded.sublist(i, end),
        caption: i == 0 ? todoUploadCaption(todo) : null,
      );
    }
    final creatorName = todo.creator?.name;
    toast(
      room.isSelf || creatorName == null
          ? '나와의 대화로 파일 ${files.length}개를 보냈습니다.'
          : '$creatorName님에게 파일 ${files.length}개를 메시지로 보냈습니다.',
    );
  } catch (e) {
    toast('파일을 보내지 못했습니다: $e');
  }
}

/// 업로드 경로가 없을 때 파일을 보낼 방 — 만든 사람과의 1:1, 내가 만들었거나 만든 사람이 없으면 나와의 대화.
Future<Room> _uploadTargetRoom(Session session, Todo todo) {
  final creatorId = todo.creator?.id;
  if (creatorId == null || creatorId == session.userId) {
    return session.openSelfChat(teamId: todo.teamId);
  }
  return session.startDm(creatorId, teamId: todo.teamId);
}

/// 메시지로 보낼 때 첫 메시지에 붙는 글.
String todoUploadCaption(Todo todo) => '[할 일] ${todo.title} — 파일을 올렸습니다.';

/// [files]를 [folder]에 복사한다 — 같은 이름이 있으면 보낸 사람 이름을 붙인다([uniqueTargetPath]). 복사한 수와 실패한 수.
Future<({int copied, int failed})> copyFilesToFolder(
  List<File> files,
  String folder, {
  required String senderName,
}) async {
  var copied = 0;
  var failed = 0;
  for (final file in files) {
    try {
      final name = file.uri.pathSegments.last;
      final target = await uniqueTargetPath(folder, name, senderName);
      await file.copy(target);
      copied++;
    } catch (_) {
      failed++;
    }
  }
  return (copied: copied, failed: failed);
}

/// [folder]에 [name]으로 올릴 경로 — 같은 이름이 이미 있으면 `이름_보낸 사람.확장자`(누가 올린 것인지 보이게), 그것도
/// 있으면 `이름_보낸 사람 (1).확장자`, `(2)`… 중 빈 이름. 보낸 사람 이름에 파일 이름으로 못 쓰는 글자(\ / : * ? " < > |)가
/// 있으면 `_`로 바꾸고, 이름이 비었으면 번호만 붙인다.
Future<String> uniqueTargetPath(
  String folder,
  String name,
  String senderName,
) async {
  final sep = AppPlatform.pathSeparator;
  final base = folder.endsWith(sep) ? folder : '$folder$sep';
  var candidate = '$base$name';
  if (!await File(candidate).exists()) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  final sender = senderName.trim().replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
  final named = sender.isEmpty ? stem : '${stem}_$sender';
  if (sender.isNotEmpty) {
    candidate = '$base$named$ext';
    if (!await File(candidate).exists()) return candidate;
  }
  for (var i = 1; ; i++) {
    candidate = '$base$named ($i)$ext';
    if (!await File(candidate).exists()) return candidate;
  }
}

// ── 공유 폴더(UNC) 안전 검사(검토 S32) ────────────────────────────────────
// downloadPath·uploadPath는 할 일을 만든 사람이 정하는데, UNC 경로(\\서버\공유\…)면 이 PC가 SMB로 그 서버에 접속하며
// Windows 로그인 정보(NTLM)를 넘기고, 올리기는 고른 파일을 그 서버로 복사한다. 그래서 폴더를 건드리기(존재 확인·탐색기·복사)
// 전에 (1) 열면 안 되는 서버(공인 IP·숫자로 꾸민 IP·WebDAV·장치 경로)는 아예 거절하고, (2) 나머지는 서버 이름을 보여 주며
// 한 번 물어본다(그 세션 동안 같은 서버는 다시 묻지 않는다). 서버 이름의 분류([folderHostKind])는 서버(todoRules.js
// folderHostKind)와 같다. 다만 서버는 점 있는 이름·한글 이름(named)을 운영자 허용 목록(TODO_FOLDER_HOSTS)에 있을 때만 저장하고
// 앱에 보내는데(목록에 없는 예전 값은 null로 보낸다 — todos.js), 앱은 그 목록을 모른다. 그래서 앱은 그런 이름을 거절하지 않고
// "사내 컴퓨터 이름이 아니다"라는 경고를 더해 묻는다 — 거절하면 운영자가 허용한 NAS·DFS 경로를 앱에서 열 수 없게 된다.

/// 공유 폴더 서버 이름의 종류 — 서버(todoRules.js folderHostKind)와 같은 분류.
enum FolderHostKind {
  /// 정식 표기의 사설·링크 로컬·루프백 IP, 또는 영문·숫자 단일 라벨(NetBIOS 이름) — 확인 창을 거쳐 연다.
  lan,

  /// 그 밖의 이름(점 있는 도메인·한글 이름 등) — 서버가 운영자 허용 목록으로 받은 것일 수 있어, 경고를 더한 확인 창을 거쳐 연다.
  named,

  /// 공인 IP, 숫자로 꾸민 IP(134744072·0x08080808·010.8.8.8·10.8), WebDAV 표기(host@SSL), 빈 이름 — 열지 않는다.
  blocked,
}

// Windows는 IPv4를 너그럽게 읽는다(inet_addr) — 점 없이 숫자만(134744072 = 8.8.8.8)·0x 16진·앞자리 0인 8진(010.8.8.8 =
// 8.8.8.8)·줄인 표기(10.8 = 10.0.0.8)도 주소로 본다. 그래서 숫자로 된 칸이 1~4개인 이름은 모두 IP로 보고, 정식 점 네 개 표기
// (앞자리 0 없음)일 때만 대역을 따진다 — 다른 표기로 공인 IP를 사내 이름·사설 IP처럼 꾸미지 못하게.
final _numericHostRe = RegExp(
  r'^(?:0x[0-9a-f]*|\d+)(?:\.(?:0x[0-9a-f]*|\d+)){0,3}$',
);
final _canonicalIpv4Re = RegExp(
  r'^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]\d|\d)\.){3}'
  r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]\d|\d)$',
);
// 점 없는 사내 컴퓨터 이름(NetBIOS·짧은 DNS 이름)으로 보는 글자 — ASCII 영문·숫자·-·_만. 전각·한자 마침표(．。｡)는 Windows가
// 이름을 풀 때(IDN 변환) '.'로 바뀌어 점 없어 보이는 이름이 인터넷 도메인(evil。com → evil.com)이 될 수 있다. 원래 글자에 대고
// 본다('K'(켈빈 기호)처럼 소문자로 바꾸면 ASCII가 되는 글자를 거르게).
final _netbiosNameRe = RegExp(r'^[a-z0-9_-]{1,63}$', caseSensitive: false);
final _uncPrefixRe = RegExp(r'^[\\/]{2}');
final _devicePathRe = RegExp(r'^[?.][\\/]');
const _ipv6LiteralSuffix = '.ipv6-literal.net';
const _folderFormError = '이 PC 드라이브(C:\\…)나 사내망 공유 폴더(\\\\서버\\…)만 열 수 있습니다.';

/// UNC 경로(\\서버\… · //서버/… — 구분자를 섞어 써도)면 서버 이름(host), 아니면 null(로컬 드라이브·상대 경로). 장치
/// 경로(\\?\·\\.\)도 호스트가 없다고 보고 null.
String? folderUncHost(String path) {
  final p = path.trim();
  if (!_uncPrefixRe.hasMatch(p)) return null;
  final after = p.substring(2);
  if (_devicePathRe.hasMatch(after)) return null; // 장치 경로
  final sep = after.indexOf(RegExp(r'[\\/]'));
  final host = sep < 0 ? after : after.substring(0, sep);
  return host.isEmpty ? null : host;
}

/// UNC 서버 이름의 종류([FolderHostKind]) — 서버 todoRules.js folderHostKind와 같은 규칙.
FolderHostKind folderHostKind(String rawHost) {
  final host = rawHost.toLowerCase();
  if (host.isEmpty || host.contains('@')) {
    return FolderHostKind.blocked; // \\host@SSL\…, \\host@port\… (WebDAV)
  }
  if (host.startsWith('[') ||
      host.contains(':') ||
      host.endsWith(_ipv6LiteralSuffix)) {
    return _isLanIpv6(_ipv6OfHost(host))
        ? FolderHostKind.lan
        : FolderHostKind.blocked;
  }
  if (_numericHostRe.hasMatch(host)) {
    return _canonicalIpv4Re.hasMatch(host) && _isLanIpv4(host)
        ? FolderHostKind.lan
        : FolderHostKind.blocked;
  }
  return _netbiosNameRe.hasMatch(rawHost)
      ? FolderHostKind.lan
      : FolderHostKind.named;
}

/// 사내망 모양의 UNC 서버 이름인지 — 정식 표기의 사설/링크로컬/루프백 IP, 영문·숫자 단일 라벨(NetBIOS).
bool isLanOnlyFolderHost(String rawHost) =>
    folderHostKind(rawHost) == FolderHostKind.lan;

/// 정식 표기(점 네 개, 앞자리 0 없음)로 확인한 IPv4가 사내망 대역인지 — 사설(RFC1918)·링크 로컬·루프백.
bool _isLanIpv4(String host) {
  final o = [for (final p in host.split('.')) int.parse(p)];
  final a = o[0];
  final b = o[1];
  return a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254) ||
      a == 127;
}

/// IPv6 표기의 서버 이름 → 주소 글자 — 대괄호([fe80::1])와 Windows의 ipv6-literal.net 표기(콜론→-, 영역 %N→sN)를 푼다.
String _ipv6OfHost(String host) {
  if (host.startsWith('[') && host.endsWith(']')) {
    return host.substring(1, host.length - 1);
  }
  if (host.endsWith(_ipv6LiteralSuffix)) {
    return host
        .substring(0, host.length - _ipv6LiteralSuffix.length)
        .replaceAll(RegExp(r's[0-9a-z]+$'), '')
        .replaceAll('-', ':');
  }
  return host;
}

/// 사내망 IPv6인지 — 고유 로컬(fc00::/7)·링크 로컬(fe80::/10)·루프백(::1)만, 형식이 틀리면 false. 바이트로 풀어 따진다
/// (글자 앞머리로 보면 fd::1 = 00fd::1 같은 줄인 표기를 고유 로컬로 잘못 본다). 영역 표시(%4)는 떼고 본다.
bool _isLanIpv6(String addr) {
  final plain = addr.replaceAll(RegExp(r'%.*$'), '');
  final List<int> b;
  try {
    b = Uri.parseIPv6Address(plain);
  } on FormatException {
    return false;
  }
  if (b.length != 16) return false;
  if (b.take(15).every((x) => x == 0) && b[15] == 1) return true; // ::1
  return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
}

/// 폴더 경로를 열거나 올리면 안 되는 형식·서버인지 — 괜찮으면 null, 아니면 사용자에게 보일 까닭. 서버 parseFolderPath와 같은
/// 규칙이되, 점 있는 이름·한글 이름(named)은 거절하지 않는다(서버가 허용 목록으로 받은 것일 수 있다 — 대신
/// [confirmRemoteFolderAccess]가 경고를 더해 묻는다).
String? remoteFolderError(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
    return _folderFormError;
  }
  if (_uncPrefixRe.hasMatch(value)) {
    final after = value.substring(2);
    if (_devicePathRe.hasMatch(after)) return _folderFormError; // \\?\  \\.\
    final segs = after.split(RegExp(r'[\\/]'));
    final host = segs.isEmpty ? '' : segs.first;
    if (host.isEmpty) return _folderFormError;
    if (segs.any((s) => s.toLowerCase() == 'davwwwroot')) {
      return _folderFormError;
    }
    if (folderHostKind(host) == FolderHostKind.blocked) {
      return '이 경로의 서버 "$host"은(는) 사내망 주소가 아니어서 안전을 위해 열지 않았습니다.';
    }
    return null;
  }
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return null; // 로컬 드라이브 경로
  return _folderFormError;
}

/// 폴더 고르기 창을 열 시작 위치로 넘겨도 되는 경로 — 이 PC 드라이브 경로면 그대로, 공유 폴더(UNC)·그 밖의 경로면 null.
/// Windows 폴더 창은 시작 위치를 받자마자 그 서버에 접속하므로(확인 창을 거치지 않는다), 저장된 할 일 경로가 UNC면 시작
/// 위치로 넘기지 않는다(검토 S32 — 편집 창의 "업로드 경로 지정"용).
String? localFolderOrNull(String? path) {
  if (path == null || path.trim().isEmpty) return null;
  if (folderUncHost(path) != null) return null;
  return remoteFolderError(path) == null ? path : null;
}

/// 이 세션에서 사용자가 "계속"을 누른 공유 서버 이름(소문자).
final _trustedFolderHosts = <String>{};

/// UNC 공유 폴더를 건드리기 전 확인 — 로컬 경로면 묻지 않고 true. 서버 이름을 보여 주고, "계속"이면 그 세션 동안 같은 서버는
/// 다시 묻지 않는다. 취소면 false. 사내 컴퓨터 이름·사설 IP가 아닌 이름(named)이면 경고를 더한다. 호출하는 쪽이 먼저
/// [remoteFolderError]로 까닭을 알리지만, 빠뜨려도 열면 안 되는 경로는 묻지 않고 false다.
Future<bool> confirmRemoteFolderAccess(BuildContext context, String path) async {
  if (remoteFolderError(path) != null) return false;
  final host = folderUncHost(path);
  if (host == null) return true; // 로컬 드라이브 경로는 묻지 않는다.
  final key = host.toLowerCase();
  if (_trustedFolderHosts.contains(key)) return true;
  // 점 있는 도메인·한글 이름은 서버의 허용 목록을 거쳐 왔겠지만, 사내 이름 모양이 아니라는 것을 분명히 알린다.
  final caution = folderHostKind(host) == FolderHostKind.named
      ? '"$host"은(는) 사내 컴퓨터 이름(영문·숫자)이나 사설 IP 주소가 아닙니다. '
            '서버 관리자가 허용한 회사 서버가 맞을 때만 계속하세요.'
      : '믿을 수 있는 사내 서버일 때만 계속하세요.';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('공유 폴더에 연결할까요?'),
      content: Text(
        '이 PC가 공유 서버 "$host"에 연결합니다.\n\n$path\n\n'
        '$caution 모르는 서버면 Windows 로그인 정보가 새어 나갈 수 있습니다.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('folder-host-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('계속'),
        ),
      ],
    ),
  );
  if (ok == true) {
    _trustedFolderHosts.add(key);
    return true;
  }
  return false;
}

/// 테스트가 세션 동안 기억한 "믿는 서버"를 비운다.
@visibleForTesting
void resetTrustedFolderHostsForTest() => _trustedFolderHosts.clear();
