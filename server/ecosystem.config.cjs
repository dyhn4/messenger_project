// pm2 설정. package.json이 "type": "module"이라 .js로 두면 ESM으로 해석돼 module.exports가
// 깨지므로 .cjs로 강제한다. 사용법은 README의 "pm2로 서버 운영하기" 참고.
module.exports = {
  apps: [
    {
      name: 'messenger-server',
      script: 'src/index.js',
      cwd: __dirname,
      watch: false, // 파일 변경 감시로 인한 예기치 않은 재시작 방지(운영 중 코드 변경은 git pull 후 수동 재시작으로).
      autorestart: true, // 크래시 시 자동 재시작.
      max_restarts: 10,
      env: { NODE_ENV: 'production' },
    },
  ],
};
