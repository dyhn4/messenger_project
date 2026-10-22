/**
 * 실시간 자막의 소리 다루기(callCaptions.js) — Egress가 웹소켓으로 흘려보내는 마이크 소리(16비트 PCM)를 말 한 마디씩 끊고, 받아쓰기
 * 서비스에 보낼 16kHz 모노 WAV로 만든다. 소켓·바깥 서비스를 모르는 순수 함수·클래스라 단위 테스트가 그대로 돌린다
 * (test/callRecordingFollowup.test.js).
 */

/**
 * 웹소켓 연결 요청 머리의 형식 → `{ sampleRate, channels }`. Egress는 Content-Type에 `audio/x-raw`와 rate·channels를 실어 보낸다
 * (예: `audio/x-raw;format=S16LE;rate=48000;channels=1`) — 없거나 못 읽으면 [fallback].
 */
export function pcmFormatFromHeaders(headers, fallback = { sampleRate: 48000, channels: 1 }) {
  const type = String(headers?.['content-type'] ?? '');
  const rate = Number(type.match(/rate=(\d+)/i)?.[1]);
  const channels = Number(type.match(/channels=(\d+)/i)?.[1]);
  return {
    sampleRate: Number.isInteger(rate) && rate >= 8000 && rate <= 192000 ? rate : fallback.sampleRate,
    channels: Number.isInteger(channels) && channels >= 1 && channels <= 8 ? channels : fallback.channels,
  };
}

/** 16비트 PCM 바이트(인터리브) → 모노 Float32(−1~1). 홀수 바이트 끝은 버린다. */
export function pcmToMono(buffer, channels) {
  const frames = Math.floor(buffer.length / 2 / channels);
  const out = new Float32Array(frames);
  for (let i = 0; i < frames; i += 1) {
    let sum = 0;
    for (let c = 0; c < channels; c += 1) sum += buffer.readInt16LE((i * channels + c) * 2);
    out[i] = sum / channels / 32768;
  }
  return out;
}

/** 모노 소리를 16kHz로(직선 보간 — 말소리 받아쓰기에는 충분하다). */
export function resampleTo16k(samples, sampleRate) {
  if (sampleRate === 16000) return samples;
  const ratio = sampleRate / 16000;
  const length = Math.floor(samples.length / ratio);
  const out = new Float32Array(length);
  for (let i = 0; i < length; i += 1) {
    const pos = i * ratio;
    const left = Math.floor(pos);
    const right = Math.min(left + 1, samples.length - 1);
    const t = pos - left;
    out[i] = samples[left] * (1 - t) + samples[right] * t;
  }
  return out;
}

/** 16kHz 모노 Float32 → WAV(16비트) 바이트. */
export function wavFromSamples(samples, sampleRate = 16000) {
  const data = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i += 1) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    data.writeInt16LE(Math.round(v * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(1, 22); // 모노
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write('data', 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

/** 말 끊기 기준 — 20ms 틀마다 소리 크기(RMS)로 말인지 본다. */
export const CAPTION_VAD = {
  frameMs: 20,
  // 이 크기(−1~1의 RMS)를 넘으면 말소리로 본다(약 −40dBFS).
  threshold: 0.01,
  // 말이 끝났다고 보는 조용한 길이, 말 앞에 붙여 둘 길이, 한 마디의 최소 말소리 길이·최대 길이.
  silenceMs: 700,
  preRollMs: 300,
  minSpeechMs: 400,
  maxUtteranceMs: 10_000,
};

/**
 * 모노 Float32 소리를 받아 말 한 마디씩 내준다 — [push]가 그동안 끝난 마디들(`{ samples, startMs }` — 시작 자리는 이 흐름의 처음부터
 * 잰 밀리초)을 돌려준다. 조용해진 지 [silenceMs]가 지나거나 한 마디가 [maxUtteranceMs]를 넘으면 끊는다. 말소리가 [minSpeechMs]보다
 * 짧은 것(기침·딸깍)은 버린다. [flush]는 남은 말을 끝낸다(연결이 끊길 때).
 */
export class Utterancer {
  constructor(sampleRate, options = {}) {
    this.rate = sampleRate;
    this.o = { ...CAPTION_VAD, ...options };
    this.frame = Math.max(1, Math.round((sampleRate * this.o.frameMs) / 1000));
    this.pending = new Float32Array(0);
    this.preRoll = [];
    this.current = null; // { frames: [], startMs, speechFrames, silentFrames }
    this.consumedFrames = 0;
  }

  frameMs(n) {
    return n * this.o.frameMs;
  }

  push(samples) {
    const joined = new Float32Array(this.pending.length + samples.length);
    joined.set(this.pending);
    joined.set(samples, this.pending.length);
    const out = [];
    let offset = 0;
    for (; offset + this.frame <= joined.length; offset += this.frame) {
      const frame = joined.subarray(offset, offset + this.frame);
      const done = this.feedFrame(Float32Array.from(frame));
      if (done) out.push(done);
    }
    this.pending = joined.slice(offset);
    return out;
  }

  feedFrame(frame) {
    let sum = 0;
    for (let i = 0; i < frame.length; i += 1) sum += frame[i] * frame[i];
    const loud = Math.sqrt(sum / frame.length) >= this.o.threshold;
    const index = this.consumedFrames++;
    const preRollFrames = Math.round(this.o.preRollMs / this.o.frameMs);
    if (!this.current) {
      if (!loud) {
        this.preRoll.push(frame);
        if (this.preRoll.length > preRollFrames) this.preRoll.shift();
        return null;
      }
      this.current = {
        frames: [...this.preRoll, frame],
        startMs: this.frameMs(index - this.preRoll.length),
        speechFrames: 1,
        silentFrames: 0,
      };
      this.preRoll = [];
      return null;
    }
    const cur = this.current;
    cur.frames.push(frame);
    if (loud) {
      cur.speechFrames += 1;
      cur.silentFrames = 0;
    } else {
      cur.silentFrames += 1;
    }
    if (this.frameMs(cur.silentFrames) >= this.o.silenceMs || this.frameMs(cur.frames.length) >= this.o.maxUtteranceMs) {
      return this.finish();
    }
    return null;
  }

  finish() {
    const cur = this.current;
    this.current = null;
    if (!cur || this.frameMs(cur.speechFrames) < this.o.minSpeechMs) return null;
    const samples = new Float32Array(cur.frames.reduce((n, f) => n + f.length, 0));
    let at = 0;
    for (const f of cur.frames) {
      samples.set(f, at);
      at += f.length;
    }
    return { samples, startMs: Math.max(0, cur.startMs) };
  }

  flush() {
    return this.finish();
  }
}

/** 받아쓰기 응답(OpenAI 호환 json 또는 글) → 자막 한 줄. 받아쓰기가 흔히 지어내는 말(조용할 때의 "시청해 주셔서 감사합니다" 등)은 버린다. */
export function captionTextFrom(response) {
  const text = (typeof response === 'string' ? response : String(response?.text ?? '')).replace(/\s+/g, ' ').trim();
  if (!text) return '';
  if (/^(시청해\s*주셔서\s*감사합니다|구독과\s*좋아요|MBC\s*뉴스)[.!]?$/i.test(text)) return '';
  return text.slice(0, 500);
}
