/**
 * 글 동시 편집(위키)의 OT(operational transformation) — 연산 하나는 구성 요소 배열이다:
 *   양의 정수 n = 글자 n개를 그대로 둠(retain), 문자열 s = s를 넣음(insert), 음의 정수 -n = 글자 n개를 지움(delete).
 * 글자 수는 UTF-16 단위(자바스크립트 문자열 길이 — 앱의 Dart 문자열과 같다)로 센다. ot.js의 TextOperation과 같은 규칙이고,
 * 앱(client/lib/services/ot_text.dart)도 똑같이 구현한다 — 두 쪽 결과가 같아야 모두의 글이 맞는다(test/otText.test.js).
 *
 * 동시에 같은 자리에 넣으면 transform(a, b)의 [a]가 앞에 온다 — 서버는 늦게 온 연산을 이미 적용한 연산에 대해 transform(늦게 온 것,
 * 적용한 것)으로 바꾸고, 앱은 아직 확인받지 못한 내 연산을 서버 연산에 대해 transform(내 것, 서버 것)으로 바꿔서 같은 결과가 된다.
 */

const isRetain = (c) => typeof c === 'number' && c > 0;
const isDelete = (c) => typeof c === 'number' && c < 0;
const isInsert = (c) => typeof c === 'string';

/** 연산 만들기 도우미 — 같은 종류는 합치고, 넣기는 지우기 앞에 둔다(같은 결과의 여러 표기를 하나로). */
class Builder {
  constructor() {
    this.ops = [];
  }
  retain(n) {
    if (n <= 0) return this;
    const last = this.ops[this.ops.length - 1];
    if (isRetain(last)) this.ops[this.ops.length - 1] = last + n;
    else this.ops.push(n);
    return this;
  }
  insert(s) {
    if (!s) return this;
    const ops = this.ops;
    const last = ops[ops.length - 1];
    if (isInsert(last)) {
      ops[ops.length - 1] = last + s;
    } else if (isDelete(last)) {
      // 지우기 바로 뒤의 넣기는 지우기 앞으로 — "지우고 넣기"와 "넣고 지우기"는 같은 결과다.
      const before = ops[ops.length - 2];
      if (isInsert(before)) ops[ops.length - 2] = before + s;
      else ops.splice(ops.length - 1, 0, s);
    } else {
      ops.push(s);
    }
    return this;
  }
  delete(n) {
    if (n <= 0) return this;
    const last = this.ops[this.ops.length - 1];
    if (isDelete(last)) this.ops[this.ops.length - 1] = last - n;
    else this.ops.push(-n);
    return this;
  }
  build() {
    return this.ops;
  }
}

/** 연산 모양이 맞는지(정수·문자열만, 0·빈 글 없음). */
export function isValidOp(op) {
  if (!Array.isArray(op)) return false;
  return op.every((c) => (typeof c === 'number' && Number.isInteger(c) && c !== 0) || (typeof c === 'string' && c.length > 0));
}

/** 같은 뜻의 짧은 꼴로. */
export function normalize(op) {
  const b = new Builder();
  for (const c of op) {
    if (isRetain(c)) b.retain(c);
    else if (isInsert(c)) b.insert(c);
    else if (isDelete(c)) b.delete(-c);
  }
  return b.build();
}

/** 이 연산을 적용할 수 있는 글 길이. */
export function baseLength(op) {
  let n = 0;
  for (const c of op) {
    if (isRetain(c)) n += c;
    else if (isDelete(c)) n -= c;
  }
  return n;
}

/** 적용한 뒤 글 길이. */
export function targetLength(op) {
  let n = 0;
  for (const c of op) {
    if (isRetain(c)) n += c;
    else if (isInsert(c)) n += c.length;
  }
  return n;
}

/** 아무것도 바꾸지 않는 연산인지(retain만). */
export function isNoop(op) {
  return op.every(isRetain);
}

/** [doc]에 [op]를 적용한다 — 길이가 맞지 않으면 던진다. */
export function apply(doc, op) {
  if (baseLength(op) !== doc.length) throw new Error('연산의 길이가 글과 맞지 않습니다.');
  let out = '';
  let i = 0;
  for (const c of op) {
    if (isRetain(c)) {
      out += doc.slice(i, i + c);
      i += c;
    } else if (isInsert(c)) {
      out += c;
    } else {
      i -= c;
    }
  }
  return out;
}

/**
 * 같은 글에서 갈라진 두 연산 [a]·[b] → [a', b'] — apply(apply(doc, a), b') === apply(apply(doc, b), a').
 * 같은 자리 넣기는 [a]가 앞.
 */
export function transform(a, b) {
  if (baseLength(a) !== baseLength(b)) throw new Error('두 연산의 길이가 다릅니다.');
  const ap = new Builder();
  const bp = new Builder();
  let i = 0;
  let j = 0;
  let x = a[i++];
  let y = b[j++];
  for (;;) {
    if (x === undefined && y === undefined) break;
    if (isInsert(x)) {
      ap.insert(x);
      bp.retain(x.length);
      x = a[i++];
      continue;
    }
    if (isInsert(y)) {
      ap.retain(y.length);
      bp.insert(y);
      y = b[j++];
      continue;
    }
    if (x === undefined || y === undefined) throw new Error('연산을 맞출 수 없습니다.');
    if (isRetain(x) && isRetain(y)) {
      const m = Math.min(x, y);
      ap.retain(m);
      bp.retain(m);
      x = x > m ? x - m : a[i++];
      y = y > m ? y - m : b[j++];
    } else if (isDelete(x) && isDelete(y)) {
      // 둘 다 같은 글자를 지웠다 — 서로 할 일이 없다.
      const m = Math.min(-x, -y);
      x = -x > m ? x + m : a[i++];
      y = -y > m ? y + m : b[j++];
    } else if (isDelete(x) && isRetain(y)) {
      const m = Math.min(-x, y);
      ap.delete(m);
      x = -x > m ? x + m : a[i++];
      y = y > m ? y - m : b[j++];
    } else if (isRetain(x) && isDelete(y)) {
      const m = Math.min(x, -y);
      bp.delete(m);
      x = x > m ? x - m : a[i++];
      y = -y > m ? y + m : b[j++];
    } else {
      throw new Error('연산을 맞출 수 없습니다.');
    }
  }
  return [ap.build(), bp.build()];
}

/** 차례로 적용할 두 연산 [a] 다음 [b] → 하나로 — apply(apply(doc, a), b) === apply(doc, compose(a, b)). */
export function compose(a, b) {
  if (targetLength(a) !== baseLength(b)) throw new Error('이어 붙일 수 없는 연산입니다.');
  const out = new Builder();
  let i = 0;
  let j = 0;
  let x = a[i++];
  let y = b[j++];
  for (;;) {
    if (x === undefined && y === undefined) break;
    if (isDelete(x)) {
      out.delete(-x);
      x = a[i++];
      continue;
    }
    if (isInsert(y)) {
      out.insert(y);
      y = b[j++];
      continue;
    }
    if (x === undefined || y === undefined) throw new Error('이어 붙일 수 없는 연산입니다.');
    if (isRetain(x) && isRetain(y)) {
      const m = Math.min(x, y);
      out.retain(m);
      x = x > m ? x - m : a[i++];
      y = y > m ? y - m : b[j++];
    } else if (isInsert(x) && isDelete(y)) {
      const m = Math.min(x.length, -y);
      x = x.length > m ? x.slice(m) : a[i++];
      y = -y > m ? y + m : b[j++];
    } else if (isInsert(x) && isRetain(y)) {
      const m = Math.min(x.length, y);
      out.insert(x.slice(0, m));
      x = x.length > m ? x.slice(m) : a[i++];
      y = y > m ? y - m : b[j++];
    } else if (isRetain(x) && isDelete(y)) {
      const m = Math.min(x, -y);
      out.delete(m);
      x = x > m ? x - m : a[i++];
      y = -y > m ? y + m : b[j++];
    } else {
      throw new Error('이어 붙일 수 없는 연산입니다.');
    }
  }
  return out.build();
}

/** 글 [from]을 [to]로 바꾸는 연산 — 앞뒤 같은 부분을 빼고 가운데를 갈아 끼운다(판 되돌리기·앱의 입력칸 변경). */
export function diffOp(from, to) {
  let start = 0;
  const max = Math.min(from.length, to.length);
  while (start < max && from.charCodeAt(start) === to.charCodeAt(start)) start += 1;
  let endFrom = from.length;
  let endTo = to.length;
  while (endFrom > start && endTo > start && from.charCodeAt(endFrom - 1) === to.charCodeAt(endTo - 1)) {
    endFrom -= 1;
    endTo -= 1;
  }
  return new Builder()
    .retain(start)
    .insert(to.slice(start, endTo))
    .delete(endFrom - start)
    .retain(from.length - endFrom)
    .build();
}

/** 커서 위치 [index]를 [op] 뒤로 옮긴다 — 같은 자리 넣기는 커서 뒤에 들어간 것으로 본다(커서는 그대로). */
export function transformIndex(index, op) {
  let pos = 0;
  let out = index;
  for (const c of op) {
    if (pos > index) break;
    if (isRetain(c)) {
      pos += c;
    } else if (isInsert(c)) {
      if (pos < index) out += c.length;
    } else {
      const n = -c;
      out -= Math.min(n, Math.max(0, index - pos));
      pos += n;
    }
  }
  return out;
}
