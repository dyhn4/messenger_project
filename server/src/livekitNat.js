import { execFile } from 'node:child_process';
import dns from 'node:dns/promises';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * 화상회의(LiveKit)를 사내망 밖(LTE/5G)에서도 쓰게 하는 미디어 주소 설정.
 *
 * LiveKit은 미디어(ICE) 후보로 자기 IP를 클라이언트에게 알려주는데, 사내 서버라 기본값은
 * 사내 IP뿐이다(use_external_ip: false — 설치 프로그램이 그렇게 만든다). 그러면 외부 클라이언트는
 * 신호(접속)까지는 돼도 영상·음성이 안 붙는다. .env에 EXTERNAL_ADDRESS가 있으면 livekit.yaml의
 * rtc 아래에 공인 IP(node_ip)와 advertise_internal_ip: true를 넣어서 **공인 IP와 사내 IP를 둘 다**
 * 알리게 한다 — 사내 클라이언트는 사내 IP로, 외부 클라이언트는 공인 IP로 붙는다(LiveKit 1.13+).
 *
 * EXTERNAL_ADDRESS가 도메인(DDNS)이면 이 서버가 DNS로 공인 IP를 알아내서 넣고, 주기적으로 다시
 * 확인해 IP가 바뀌면 고친다. livekit.yaml이 바뀌면 LiveKit을 재시작해야 반영되는데, 설치형
 * 서버(nssm 서비스)면 여기서 직접 재시작하고 개발 환경이면 콘솔에 알리기만 한다.
 *
 * 공유기에서는 LiveKit의 미디어 포트(rtc.port_range_start~end UDP, rtc.tcp_port TCP)를 이 PC로
 * 포워딩해야 한다. 신호(접속)는 메인 HTTPS 포트로 프록시하므로(livekitProxy.js) 7880은 안 연다.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.join(__dirname, '..');

const MANAGED_KEYS = ['use_external_ip', 'node_ip', 'advertise_internal_ip', 'skip_external_ip_validation'];
const MANAGED_COMMENT = '# TangoTalk 서버가 .env의 EXTERNAL_ADDRESS에 맞춰 관리함(server/src/livekitNat.js)';
const LIVEKIT_SERVICE_NAME = 'TangoTalkLiveKit';
const DNS_RECHECK_MS = 10 * 60 * 1000;

/**
 * livekit.yaml 본문의 rtc 블록에서 공인 IP 관련 키만 [publicIp]에 맞게 바꾼 결과. 다른 줄
 * (포트·TURN·키 등 관리자가 고쳤을 수 있는 것)은 그대로 둔다. [publicIp]가 null이면 사내망
 * 전용(use_external_ip: false만).
 */
export function applyLivekitNat(text, publicIp) {
  // 외부 주소를 한 번도 안 쓴 서버면 관리자가 만든 설정을 그대로 둔다(괜히 LiveKit을 재시작하지 않게).
  if (!publicIp && !text.includes(MANAGED_COMMENT)) return text;
  const nl = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const isManaged = (line) =>
    line.trim() === MANAGED_COMMENT || MANAGED_KEYS.some((k) => new RegExp(`^\\s+${k}\\s*:`).test(line));

  // 외부 주소를 끄면 관리 표시까지 지우고 설치 프로그램이 만든 원래 모양(사내 IP만)으로 되돌린다.
  const desired = publicIp
    ? [MANAGED_COMMENT, 'use_external_ip: false', `node_ip: ${publicIp}`, 'advertise_internal_ip: true']
    : ['use_external_ip: false'];

  const rtcStart = lines.findIndex((l) => /^rtc:\s*(#.*)?$/.test(l));
  if (rtcStart < 0) {
    while (lines.length && lines[lines.length - 1] === '') lines.pop();
    lines.push('rtc:', ...desired.map((l) => `  ${l}`), '');
    return lines.join(nl);
  }

  // rtc 블록 = 다음 최상위 키(들여쓰기 없는, 주석 아닌 줄) 전까지.
  let rtcEnd = rtcStart + 1;
  while (rtcEnd < lines.length && (lines[rtcEnd] === '' || /^\s/.test(lines[rtcEnd]) || /^#/.test(lines[rtcEnd]))) {
    rtcEnd += 1;
  }
  const block = lines.slice(rtcStart + 1, rtcEnd).filter((l) => !isManaged(l));
  const indent = block.find((l) => /^\s+\S/.test(l))?.match(/^\s+/)[0] ?? '  ';
  // 블록 끝의 빈 줄·최상위 주석은 그 뒤에 그대로 두고, 관리 키는 실제 rtc 항목 바로 뒤에 넣는다.
  let insertAt = block.length;
  while (insertAt > 0 && (block[insertAt - 1] === '' || /^#/.test(block[insertAt - 1]))) insertAt -= 1;
  block.splice(insertAt, 0, ...desired.map((l) => `${indent}${l}`));

  return [...lines.slice(0, rtcStart + 1), ...block, ...lines.slice(rtcEnd)].join(nl);
}

/** livekit.yaml에서 공유기에 열어야 할 미디어 포트(안내용). 못 읽으면 기본값. */
export function livekitMediaPorts(text) {
  const num = (key, fallback) => Number(text.match(new RegExp(`^\\s+${key}\\s*:\\s*(\\d+)`, 'm'))?.[1] ?? fallback);
  return { udpStart: num('port_range_start', 50000), udpEnd: num('port_range_end', 60000), tcp: num('tcp_port', 7881) };
}

function isPrivateIPv4(ip) {
  return /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.)/.test(ip);
}

/** 설치형: {app}\livekit\livekit.yaml, 개발: server/.livekit/livekit.yaml. LIVEKIT_CONFIG_PATH로 덮어쓸 수 있다. */
function findLivekitConfig() {
  const candidates = [
    process.env.LIVEKIT_CONFIG_PATH,
    path.join(serverDir, '..', 'livekit', 'livekit.yaml'),
    path.join(serverDir, '.livekit', 'livekit.yaml'),
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p)) ?? null;
}

async function resolvePublicIp(externalAddress) {
  if (!externalAddress) return null;
  if (net.isIPv4(externalAddress.host)) return externalAddress.host;
  try {
    const { address } = await dns.lookup(externalAddress.host, { family: 4 });
    if (isPrivateIPv4(address)) {
      console.warn(`[livekit] ${externalAddress.host}이(가) 사내 IP(${address})로 조회돼 화상회의 공인 IP로 쓰지 않습니다.`);
      return null;
    }
    return address;
  } catch (e) {
    console.warn(`[livekit] ${externalAddress.host}의 공인 IP를 조회하지 못했습니다(${e.code ?? e.message}) — 화상회의 설정은 그대로 둡니다.`);
    return undefined; // 모름 — 지금 설정을 건드리지 않는다.
  }
}

function restartLivekitService() {
  const nssm = path.join(serverDir, '..', 'tools', 'nssm.exe');
  if (!fs.existsSync(nssm)) {
    console.log('[livekit] ⚠ livekit.yaml을 바꿨습니다 — LiveKit을 재시작해야 화상회의에 반영됩니다.');
    return;
  }
  execFile(nssm, ['restart', LIVEKIT_SERVICE_NAME], { windowsHide: true }, (err) => {
    if (err) console.warn(`[livekit] LiveKit 서비스 재시작 실패 — 직접 재시작하세요: ${err.message}`);
    else console.log('[livekit] 바뀐 설정으로 LiveKit 서비스를 재시작했습니다.');
  });
}

async function syncOnce(configPath, externalAddress) {
  const publicIp = await resolvePublicIp(externalAddress);
  if (publicIp === undefined) return;
  const before = fs.readFileSync(configPath, 'utf8');
  const after = applyLivekitNat(before, publicIp);
  if (after === before) return;
  fs.writeFileSync(configPath, after);
  console.log(`[livekit] 화상회의 미디어 주소를 ${publicIp ? `공인 IP ${publicIp} + 사내 IP` : '사내 IP만'}로 맞췄습니다(${configPath}).`);
  restartLivekitService();
}

/**
 * 서버 시작 시 한 번 맞추고, 외부 주소가 도메인이면 주기적으로 다시 맞춘다. LiveKit을 다른 장비에
 * 띄웠거나(LIVEKIT_URL) livekit.yaml을 못 찾으면 아무것도 안 한다.
 * @returns 공유기에 열어야 할 미디어 포트(안내용) 또는 null.
 */
export async function startLivekitNatSync({ externalAddress, enabled }) {
  if (!enabled) return null;
  const configPath = findLivekitConfig();
  if (!configPath) return null;
  try {
    await syncOnce(configPath, externalAddress);
  } catch (e) {
    console.warn(`[livekit] livekit.yaml을 고치지 못했습니다: ${e.message}`);
  }
  if (externalAddress && !net.isIPv4(externalAddress.host)) {
    setInterval(() => syncOnce(configPath, externalAddress).catch(() => {}), DNS_RECHECK_MS).unref();
  }
  return livekitMediaPorts(fs.readFileSync(configPath, 'utf8'));
}
