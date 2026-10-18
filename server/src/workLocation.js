/**
 * 출퇴근 위치(순수 규칙) — 앱이 출근·퇴근을 누를 때 보낸 기기 위치(GPS — 위도·경도·정확도 m)를 확인하고, 범위에 사무실 위치를 정해 두면
 * 거리를 재 "사무실 밖에서 사무실 출근"을 알린다. 외근은 위치를 꼭 받게 할 수 있다(requireFieldLocation). 위치는 출퇴근 기록에만 남고
 * 계속 따라다니지 않는다. DB는 groupware.js. `node --test`로 시험한다(test/workFollowup.test.js).
 */

/** 사무실 반경(m) — 50m~5km. */
export const OFFICE_RADIUS_MIN = 50;
export const OFFICE_RADIUS_MAX = 5000;
/** 받지 않을 만큼 흐린 위치(정확도 m). */
export const LOCATION_ACCURACY_MAX = 5000;

const num = (v) => (typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN);

/** 위치 입력 `{ lat, lng, accuracy? }` → `{ location }`(없으면 null) | `{ error }`. 좌표는 소수 6자리(약 10cm)로 자른다. */
export function parseLocation(input) {
  if (input === undefined || input === null) return { location: null };
  const lat = num(input?.lat);
  const lng = num(input?.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return { error: '위치를 확인하세요.' };
  const accuracy = num(input?.accuracy);
  if (Number.isFinite(accuracy) && (accuracy < 0 || accuracy > LOCATION_ACCURACY_MAX)) return { error: '위치가 너무 흐립니다. 잠시 뒤 다시 누르세요.' };
  const round = (v, d) => Math.round(v * 10 ** d) / 10 ** d;
  return { location: { lat: round(lat, 6), lng: round(lng, 6), accuracy: Number.isFinite(accuracy) ? Math.round(accuracy) : null } };
}

/** 사무실 위치 입력 `{ lat, lng, radius }` | null → `{ office }` | `{ error }`. */
export function parseOfficeLocation(input) {
  if (input === null) return { office: null };
  const parsed = parseLocation(input);
  if (parsed.error || !parsed.location) return { error: '사무실 위치(위도·경도)를 확인하세요.' };
  const radius = num(input?.radius ?? 200);
  if (!Number.isInteger(radius) || radius < OFFICE_RADIUS_MIN || radius > OFFICE_RADIUS_MAX) {
    return { error: `사무실 반경은 ${OFFICE_RADIUS_MIN}~${OFFICE_RADIUS_MAX}m로 정하세요.` };
  }
  return { office: { lat: parsed.location.lat, lng: parsed.location.lng, radius } };
}

/** 두 위치 사이 거리(m, 하버사인). */
export function distanceMeters(a, b) {
  const R = 6_371_000;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return Math.round(2 * R * Math.asin(Math.min(1, Math.sqrt(h))));
}

/**
 * 출근 위치 확인 — [mode]('office'|'field'|'remote'), [location](없을 수 있음), [office](범위의 사무실 위치), [requireField](외근은 위치
 * 필수). `{ error }` | `{ distance(사무실까지 m — 모르면 null), outside(사무실 출근인데 반경 밖 — 정확도만큼 봐준다) }`.
 */
export function checkClockLocation({ mode, location, office = null, requireField = false }) {
  if (mode === 'field' && requireField && !location) {
    return { error: '외근은 위치를 함께 보내야 합니다. 앱의 위치 권한을 켜고 다시 누르세요.' };
  }
  if (!location || !office) return { distance: null, outside: false };
  const distance = distanceMeters(location, office);
  return { distance, outside: mode === 'office' && distance > office.radius + (location.accuracy ?? 0) };
}
