// 시작 메뉴 "백업"(installer/Backup-Data.ps1)이 부르는 전체 백업 — 관리자 콘솔 "백업" 탭의 "지금 백업"과 같다(DB·비밀값·인증서를
// 백업 암호로 암호화해 이 PC의 백업 폴더에 두고, 외부 위치를 정했으면 그곳에 복사하고 첨부파일까지 맞춘다 — src/backup.js).
// 서버가 돌고 있어도 된다(pg_dump는 그 시점의 일관된 스냅샷을 뜬다). 서버의 예약 백업과는 백업 폴더의 잠금 파일로 겹치지 않는다.
//
// 종료 코드: 0 성공 · 2 이 PC에는 백업했지만 외부 위치 복사 실패 · 3 백업 암호를 아직 정하지 않음(Backup-Data.ps1이 예전처럼 DB만
// 백업한다) · 4 다른 백업이 진행 중 · 1 그 밖의 실패.
//
// 사용법(현재 폴더 = server 폴더 — .env를 여기서 읽는다): node scripts/backup-now.mjs
import 'dotenv/config';
import { BackupBusyError, backupPaths, loadBackupSettings, performBackup } from '../src/backupService.js';

function formatBytes(n) {
  if (!Number.isFinite(n)) return '?';
  if (n < 1024 * 1024) return `${Math.max(1, Math.round(n / 1024))}KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)}MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)}GB`;
}

let code = 0;
try {
  const settings = await loadBackupSettings();
  if (!settings.ready) {
    console.log(settings.passwordError ?? '백업 암호를 아직 정하지 않았습니다 — 관리자 콘솔 "백업" 탭에서 정하면 전체 백업을 합니다.');
    code = 3;
  } else {
    let lastProgress = 0;
    const status = await performBackup({
      kind: 'manual',
      owner: 'script',
      onPhase: (phase) => console.log(`- ${phase}...`),
      onProgress: (done, total) => {
        if (total > 0 && (done === total || Date.now() - lastProgress > 2000)) {
          lastProgress = Date.now();
          console.log(`  첨부파일 ${done}/${total}`);
        }
      },
    });
    console.log('');
    console.log(`백업 완료: ${status.lastBackup.name} (${formatBytes(status.lastBackup.bytes)})`);
    console.log(`저장 위치: ${backupPaths.localRoot}`);
    if (status.external?.ok) {
      const u = status.external.uploads;
      console.log(`외부 위치: ${status.external.path} — 첨부파일 ${u?.total ?? 0}개(새로 보냄 ${u?.copied ?? 0}개)`);
      if (u?.deletionSkipped) {
        console.log(`주의: 첨부파일 ${u.deletionSkipped}개가 한꺼번에 사라져 외부 백업에서는 지우지 않았습니다 — 첨부파일 저장소를 확인하세요.`);
      }
    } else if (status.external) {
      console.log(`외부 위치 복사 실패: ${status.external.error}`);
      code = 2;
    } else {
      console.log('외부 백업 위치(NAS·외장 드라이브)를 정하지 않아 이 PC에만 백업했습니다 — 첨부파일은 백업되지 않았습니다.');
    }
  }
} catch (e) {
  console.error(`백업 실패: ${e?.message ?? e}`);
  code = e instanceof BackupBusyError ? 4 : 1;
}
// DB 연결 풀이 열려 있어 그냥 두면 끝나지 않는다.
process.exit(code);
