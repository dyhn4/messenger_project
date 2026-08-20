export const PORT = process.env.PORT || 3000;

// 개인용 LAN 서버 기준 기본값입니다. 외부에 노출할 계획이면 반드시
// 환경변수 JWT_SECRET을 따로 설정하세요 (예: set JWT_SECRET=... & npm start).
export const JWT_SECRET = process.env.JWT_SECRET || 'dev-only-change-this-secret';
