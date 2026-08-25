// 새 기기용 페어링 코드를 발급받는다. 서버가 pm2처럼 콘솔 입력을 받을 수 없는 방식으로
// 떠있어도 쓸 수 있도록, 이 PC 안에서만 호출 가능한 /admin/generate를 호출한다(pairing.js 참고).
// 사용법: npm run pair (반드시 서버가 이미 떠있는 같은 PC에서 실행)
import { PAIRING_PORT } from '../src/config.js';

const res = await fetch(`http://127.0.0.1:${PAIRING_PORT}/admin/generate`, { method: 'POST' }).catch((e) => {
  console.error('서버에 연결할 수 없습니다. 서버가 떠있는지 확인하세요:', e.message);
  process.exit(1);
});

if (!res.ok) {
  console.error('코드 발급 실패:', res.status);
  process.exit(1);
}

const { code, expiresInMs } = await res.json();
console.log(`[pairing] 새 기기 연결 코드: ${code} (유효시간 ${Math.round(expiresInMs / 1000)}초, 1회용)`);
