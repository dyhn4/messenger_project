// 할 일 폴더 경로(downloadPath·uploadPath)의 서버 이름 검사(검토 S32) — `node --test test/todoFolderPath.test.js`
// (DB·서버 없이 돈다). 담당자의 PC가 UNC 경로로 SMB 접속하며 Windows 로그인 정보(NTLM)를 넘기거나 파일을 복사하므로,
// 이 PC 드라이브이거나 "사내망에서만 닿는 서버"일 때만 받아야 한다. 흔한 NAS 공유(\\NAS\공유, \\192.168.x.x\share)는
// 그대로 되고, 공인 IP·도메인·WebDAV·장치 경로와 숫자·유니코드로 꾸민 이름은 거르는지, 예전에 저장된 경로는 앱에 보내지 않는지,
// 그리고 경로는 담당자가 못 바꾸는지를 본다. 앱(client/test/todo_folder_host_test.dart)도 같은 분류를 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  folderHostKind,
  folderPathHost,
  isAllowedFolderHost,
  parseFolderHostList,
  parseFolderPath,
  parseTodoCreate,
  parseTodoPatch,
  patchDenial,
  storedFolderPath,
} from '../src/todoRules.js';

const ok = (raw, hosts) => {
  const r = parseFolderPath(raw, '파일 업로드', hosts);
  assert.equal(r.error, undefined, `허용돼야 함: ${raw}`);
  return r.value;
};
const bad = (raw, hosts) => {
  const r = parseFolderPath(raw, '파일 업로드', hosts);
  assert.ok(r.error, `거절돼야 함: ${raw}`);
  return r.error;
};

test('빈 값·형식 — null/길이/제어문자', () => {
  assert.deepEqual(parseFolderPath(undefined, '파일 업로드'), { value: null });
  assert.deepEqual(parseFolderPath(null, '파일 업로드'), { value: null });
  assert.deepEqual(parseFolderPath('   ', '파일 업로드'), { value: null });
  assert.ok(parseFolderPath(3, '파일 업로드').error);
  bad('C:/a\nb'); // 제어 문자
  bad('C:/' + 'a'.repeat(1001)); // 길이 초과
});

test('로컬 드라이브 경로는 허용(역슬래시·슬래시 모두), 드라이브 문자가 아니면 거절', () => {
  assert.equal(ok(String.raw`C:\자료`), String.raw`C:\자료`);
  assert.equal(ok('D:/share/out'), 'D:/share/out');
  assert.equal(ok('  Z:\\결과  '), 'Z:\\결과'); // 앞뒤 공백은 떼고 저장
  bad('자료'); // 상대 경로
  bad('/etc/passwd'); // 단일 슬래시(로컬 드라이브 아님)
  bad('C:'); // 드라이브만(구분자 없음)
});

test('UNC — 정식 표기의 사설/링크로컬 IP와 영문·숫자 단일 라벨(NetBIOS)은 허용', () => {
  assert.equal(ok(String.raw`\\nas\공유\보고서`), String.raw`\\nas\공유\보고서`);
  ok(String.raw`\\NAS-01\공유`);
  ok(String.raw`\\file_srv\x`);
  ok(String.raw`\\10.0.0.66\drop`);
  ok(String.raw`\\192.168.0.5\share`);
  ok(String.raw`\\172.16.1.9\x`);
  ok(String.raw`\\169.254.1.1\x`);
  ok(String.raw`\\127.0.0.1\x`);
  ok('//nas/공유'); // 슬래시 표기도 UNC로 본다
  ok(String.raw`\/nas\공유`); // 구분자를 섞어 써도 UNC(Windows가 그렇게 읽는다)
  ok(String.raw`\\[fe80::1]\share`); // 링크로컬 IPv6
  ok(String.raw`\\[fd12:3456::1]\share`); // ULA IPv6
  ok(String.raw`\\fe80--1s4.ipv6-literal.net\share`); // Windows의 IPv6 UNC 표기(영역 s4)
});

test('거절 문구 — 공인 IP는 사내망 주소가 아니라고, 점 있는 이름은 관리자에게 허용을 요청하라고', () => {
  assert.match(bad(String.raw`\\8.8.8.8\share`), /'8\.8\.8\.8'은\(는\) 사내망 주소가 아닙니다/);
  const named = bad(String.raw`\\nas.corp.local\공유`);
  assert.match(named, /'nas\.corp\.local'은\(는\) 허용된 사내 서버가 아닙니다/);
  assert.match(named, /서버 관리자에게 허용을 요청하세요/);
});

test('UNC — 공인 IP·도메인(FQDN)·한글 이름은 목록 없이는 거절', () => {
  bad(String.raw`\\8.8.8.8\share`);
  bad(String.raw`\\203.0.113.7\drop`);
  bad(String.raw`\\172.32.0.1\x`); // 172.16~31만 사설 — 32는 공인
  bad(String.raw`\\0.0.0.0\x`);
  bad(String.raw`\\files.evil.example\drop`);
  bad(String.raw`\\nas.corp.local\공유`); // 점 있는 FQDN은 목록에 없으면 거절
  bad(String.raw`\\nas.\공유`); // 끝에 점(루트까지 적은 도메인)
  bad(String.raw`\\사내서버\공유`); // ASCII가 아닌 이름은 목록으로만
  bad(String.raw`\\[2001:db8::1]\share`); // 공인 IPv6
  bad(String.raw`\\2001-db8--1.ipv6-literal.net\share`);
});

test('UNC — 숫자로 꾸민 IPv4는 사내망 대역처럼 보여도 거절(Windows가 10진·16진·8진·줄인 표기를 주소로 읽는다)', () => {
  bad(String.raw`\\134744072\s`); // = 8.8.8.8 (점 없는 10진)
  bad(String.raw`\\0x08080808\s`); // = 8.8.8.8 (16진)
  bad(String.raw`\\0X8080808\s`);
  bad(String.raw`\\010.8.8.8\s`); // 앞자리 0 = 8진 → 8.8.8.8 (Number로 읽으면 10.8.8.8 사설처럼 보인다)
  bad(String.raw`\\10.0.0.010\s`); // 앞자리 0이 있는 칸은 모두 거절
  bad(String.raw`\\10.8\s`); // 줄인 표기(10.0.0.8)
  bad(String.raw`\\0x0a000001\s`); // = 10.0.0.1이어도 정식 표기만 받는다
  bad(String.raw`\\2130706433\s`); // = 127.0.0.1
  // 숫자처럼 시작하지만 주소로 읽히지 않는 이름은 그대로 사내 이름.
  ok(String.raw`\\2f\s`);
  ok(String.raw`\\1e5\s`);
  ok(String.raw`\\0xnas\s`);
});

test('UNC — 유니코드로 꾸민 이름(전각·한자 마침표, 켈빈 기호)은 단일 라벨로 보지 않는다', () => {
  bad(String.raw`\\evil` + '\u3002' + String.raw`com\s`); // 。 → IDN 변환에서 '.'
  bad(String.raw`\\evil` + '\uff0e' + String.raw`com\s`); // ．
  bad(String.raw`\\evil` + '\uff61' + String.raw`com\s`); // ｡
  bad('\\\\\u212Aevin\\s'); // K(켈빈 기호) — 소문자로 바꾸면 ASCII k가 되지만 원래 글자는 ASCII가 아니다
});

test('UNC — IPv6 표기는 형식·대역을 정확히 본다', () => {
  bad(String.raw`\\[fd::1]\s`); // 00fd::1 — 글자 앞머리는 fd지만 고유 로컬(fc00::/7)이 아니다
  bad(String.raw`\\[::ffff:8.8.8.8]\s`); // IPv4가 든 IPv6
  bad(String.raw`\\[evil.com]\s`); // 대괄호 안이 주소가 아님
  bad(String.raw`\\evil.ipv6-literal.net\s`);
  bad(String.raw`\\fd00:evil\s`);
  ok(String.raw`\\[::1]\s`);
});

test('UNC — WebDAV·장치 경로·http(s)는 거절', () => {
  bad(String.raw`\\nas@SSL\DavWWWRoot\x`); // host@SSL
  bad(String.raw`\\nas@8080\share`); // host@port
  bad(String.raw`\\live.sysinternals.com\DavWWWRoot`);
  bad(String.raw`\\nas\DavWWWRoot\x`); // DavWWWRoot 세그먼트(LAN 이름이어도)
  bad(String.raw`\\?\C:\Windows`); // 장치 경로
  bad(String.raw`\\?\UNC\evil.example\x`);
  bad(String.raw`\\.\PhysicalDrive0`);
  bad('http://evil.example/share');
  bad('https://evil.example/share');
  bad(String.raw`\\`); // 호스트 없음
});

test('TODO_FOLDER_HOSTS 목록 — 점 있는 이름·한글 이름의 사내 서버를 따로 허용, IP·@는 목록으로도 안 된다', () => {
  const hosts = parseFolderHostList(' NAS.corp.local , files.example.com, 사내서버, 203.0.113.5, nas@ssl ');
  assert.deepEqual([...hosts], ['nas.corp.local', 'files.example.com', '사내서버', '203.0.113.5', 'nas@ssl']);
  ok(String.raw`\\nas.corp.local\공유`, hosts); // 목록에 있으면 허용(대소문자 무시)
  ok(String.raw`\\FILES.EXAMPLE.COM\x`, hosts);
  ok(String.raw`\\사내서버\공유`, hosts);
  // 한글 이름은 정규형이 달라도(NFD) 같은 이름으로 본다.
  ok('\\\\' + '사내서버'.normalize('NFD') + '\\공유', hosts);
  bad(String.raw`\\other.example.com\x`, hosts); // 목록에 없는 도메인은 여전히 거절
  bad(String.raw`\\203.0.113.5\x`, hosts); // IP는 목록과 상관없이 사내망 대역만
  bad(String.raw`\\nas@SSL\x`, hosts); // WebDAV 표기는 목록으로도 안 된다
  assert.equal(parseFolderHostList('').size, 0);
  assert.equal(parseFolderHostList(undefined).size, 0);
});

test('folderHostKind·isAllowedFolderHost 단위 — lan/named/blocked', () => {
  for (const h of ['nas', 'NAS-01', '10.1.2.3', '192.168.1.1', '[fe80::1]', '[fe80::1%4]']) {
    assert.equal(folderHostKind(h), 'lan', h);
  }
  for (const h of ['nas.corp.local', '사내서버', 'evil\u3002com']) assert.equal(folderHostKind(h), 'named', h);
  for (const h of ['8.8.8.8', '134744072', '010.8.8.8', 'nas@ssl', '', '[2001:db8::1]']) {
    assert.equal(folderHostKind(h), 'blocked', h);
  }
  assert.equal(folderHostKind(undefined), 'blocked');
  assert.ok(isAllowedFolderHost('nas'));
  assert.ok(!isAllowedFolderHost('nas.corp.local'));
  assert.ok(isAllowedFolderHost('nas.corp.local', new Set(['nas.corp.local'])));
  assert.ok(!isAllowedFolderHost('8.8.8.8', new Set(['8.8.8.8'])));
});

test('folderPathHost — UNC 서버 이름만(로그용), 아니면 null', () => {
  assert.equal(folderPathHost(String.raw`\\nas\x`), 'nas');
  assert.equal(folderPathHost('//nas.corp.local/x'), 'nas.corp.local');
  assert.equal(folderPathHost(String.raw`\/nas\x`), 'nas');
  assert.equal(folderPathHost('C:/x'), null);
  assert.equal(folderPathHost(String.raw`\\?\C:\x`), null);
  assert.equal(folderPathHost(String.raw`\\`), null);
  assert.equal(folderPathHost(null), null);
});

test('storedFolderPath — 예전에 저장된 경로 중 지금 규칙에 맞지 않는 것은 앱에 보내지 않는다(옛 앱 보호)', () => {
  const hosts = parseFolderHostList('nas.corp.local');
  assert.equal(storedFolderPath(String.raw`\\nas\결과`), String.raw`\\nas\결과`);
  assert.equal(storedFolderPath(String.raw`C:\자료`), String.raw`C:\자료`);
  assert.equal(storedFolderPath(null), null);
  assert.equal(storedFolderPath(undefined), null);
  // 이 규칙 전에 들어간 공인 서버·WebDAV·장치 경로·숫자로 꾸민 IP.
  for (const legacy of [
    String.raw`\\8.8.8.8\drop`,
    String.raw`\\files.evil.example\drop`,
    String.raw`\\evil@SSL\DavWWWRoot\x`,
    String.raw`\\?\UNC\evil.example\x`,
    String.raw`\\134744072\s`,
    'https://evil.example/share',
  ]) {
    assert.equal(storedFolderPath(legacy, hosts), null, legacy);
  }
  // 운영자가 목록에 적은 이름이면 다시 보인다(DB 값은 그대로라).
  assert.equal(storedFolderPath(String.raw`\\nas.corp.local\공유`), null);
  assert.equal(storedFolderPath(String.raw`\\nas.corp.local\공유`, hosts), String.raw`\\nas.corp.local\공유`);
});

test('parseTodoCreate/parseTodoPatch — 경로를 함께 검사하고, 목록(folderHosts)을 넘긴다', () => {
  const local = String.raw`C:\자료`;
  const created = parseTodoCreate({ title: '보고서', downloadPath: local, uploadPath: '' });
  assert.equal(created.downloadPath, local);
  assert.equal(created.uploadPath, null);
  // 공인 호스트면 만들기가 통째로 거절된다.
  assert.ok(parseTodoCreate({ title: 't', uploadPath: String.raw`\\evil.example\x` }).error);
  assert.ok(parseTodoCreate({ title: 't', uploadPath: String.raw`\\134744072\x` }).error);
  // 목록에 있으면 만들기 통과.
  const hosts = parseFolderHostList('nas.corp.local');
  assert.equal(
    parseTodoCreate({ title: 't', uploadPath: String.raw`\\nas.corp.local\x` }, Date.now(), [], hosts).uploadPath,
    String.raw`\\nas.corp.local\x`,
  );
  // 수정도 같은 검사.
  assert.deepEqual(parseTodoPatch({ uploadPath: String.raw`\\nas\결과` }).fields, { uploadPath: String.raw`\\nas\결과` });
  assert.ok(parseTodoPatch({ uploadPath: String.raw`\\8.8.8.8\x` }).error);
  assert.ok(parseTodoPatch({ downloadPath: String.raw`\\010.8.8.8\x` }).error);
  assert.deepEqual(parseTodoPatch({ downloadPath: null }).fields, { downloadPath: null });
});

test('경로는 담당자가 못 바꾼다 — 만든 사람(또는 관리 권한 담당자)만(검토 S32)', () => {
  assert.equal(patchDenial('creator', 'u-creator', ['downloadPath']), null);
  assert.equal(patchDenial('assignee', 'u-creator', ['uploadPath']).error, '담당자는 파일 경로를 바꿀 수 없습니다.');
  assert.equal(patchDenial('assignee', 'u-creator', ['title', 'downloadPath']).error, '담당자는 파일 경로를 바꿀 수 없습니다.');
  // 담당자 목록과 경로를 함께 보내면 담당자 목록 문구가 먼저.
  assert.equal(
    patchDenial('assignee', 'u-creator', ['assigneeIds', 'uploadPath']).error,
    '담당자는 담당자 목록을 바꿀 수 없습니다.',
  );
  // 만든 사람 계정이 사라진 할 일은 관리 권한 담당자가 바꾼다.
  assert.equal(patchDenial('assignee', null, ['downloadPath']), null);
  // 경로만 보낸 담당자도 수정 권한 자체는 있으니(canEdit) 경로 문구, 보기만 하는 사람은 수정 권한 문구.
  assert.equal(patchDenial('viewer', 'u-creator', ['uploadPath']).error, '이 할 일을 수정할 권한이 없습니다.');
});
