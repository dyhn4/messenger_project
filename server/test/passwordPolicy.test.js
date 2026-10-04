// 새 비밀번호 규칙(passwordPolicy.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { passwordPolicyError } from '../src/passwordPolicy.js';

test('8자 미만이면 거부 — 예전 기준(4자)은 더 이상 통과하지 않는다', () => {
  assert.equal(passwordPolicyError('abc1234'), '비밀번호는 8자 이상이어야 합니다.');
  assert.equal(passwordPolicyError('abcd'), '비밀번호는 8자 이상이어야 합니다.');
  assert.equal(passwordPolicyError(undefined), '비밀번호는 8자 이상이어야 합니다.');
  assert.equal(passwordPolicyError(12345678), '비밀번호는 8자 이상이어야 합니다.');
});

test('8~20자는 통과, 20자 초과는 거부', () => {
  assert.equal(passwordPolicyError('abcd1234'), null);
  assert.equal(passwordPolicyError('a'.repeat(20)), null);
  assert.equal(passwordPolicyError('a'.repeat(21)), '비밀번호는 20자 이하여야 합니다.');
});
