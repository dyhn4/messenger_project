// "링크" 모아보기 검색어 줄 단위 거르기 단위 테스트 — `node --test test/` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { extractUrls, linkRowMatchesQuery } from '../src/linkPreview.js';

const text = '두 링크 https://example.com/beta 그리고 https://example.com/gamma?x=1';
const urls = extractUrls(text);

test('linkRowMatchesQuery: 검색어가 없으면 모든 줄이 해당한다', () => {
  assert.equal(linkRowMatchesQuery('', { url: urls[0], text, urls }), true);
});

test('linkRowMatchesQuery: 검색어가 한 주소에만 있으면 그 줄만 해당한다(같은 메시지의 다른 링크는 아니다)', () => {
  assert.equal(linkRowMatchesQuery('beta', { url: urls[0], text, urls }), true);
  assert.equal(linkRowMatchesQuery('beta', { url: urls[1], text, urls }), false);
});

test('linkRowMatchesQuery: 주소를 뺀 본문(설명)에 있으면 그 메시지의 모든 링크가 해당한다', () => {
  assert.equal(linkRowMatchesQuery('그리고', { url: urls[0], text, urls }), true);
  assert.equal(linkRowMatchesQuery('그리고', { url: urls[1], text, urls }), true);
});

test('linkRowMatchesQuery: 미리보기 제목·사이트 이름은 그 줄에서만 본다', () => {
  assert.equal(linkRowMatchesQuery('뉴스', { url: urls[0], text, urls, title: '오늘의 뉴스' }), true);
  assert.equal(linkRowMatchesQuery('뉴스', { url: urls[1], text, urls }), false);
  assert.equal(linkRowMatchesQuery('example', { url: urls[0], text, urls, siteName: 'Example Site' }), true);
});

test('linkRowMatchesQuery: 주소 글자는 본문 매칭에서 빠진다(주소 안 글자로 다른 줄이 딸려 나오지 않는다)', () => {
  assert.equal(linkRowMatchesQuery('gamma', { url: urls[0], text, urls }), false);
  assert.equal(linkRowMatchesQuery('gamma', { url: urls[1], text, urls }), true);
});
