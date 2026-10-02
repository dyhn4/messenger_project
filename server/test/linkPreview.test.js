import assert from 'node:assert/strict';
import { test } from 'node:test';

import { parseOgTags } from '../src/linkPreview.js';

const pageUrl = 'https://example.com/post/1';

test('og:image가 있으면 그대로 쓴다', () => {
  const html = `
    <meta property="og:title" content="제목" />
    <meta property="og:image" content="https://cdn.example.com/a.jpg" />
  `;
  const r = parseOgTags(html, pageUrl);
  assert.equal(r.title, '제목');
  assert.equal(r.imageUrl, 'https://cdn.example.com/a.jpg');
});

test('og:image가 없으면(더쿠 등) 본문 첫 실제 사진을 대신 쓴다', () => {
  const html = `
    <title>더쿠 - 제목</title>
    <img src="/layout/logo.png" width="40" height="40">
    <img width="700" height="442" src="https://img.example.com/photo.jpg" alt="">
  `;
  const r = parseOgTags(html, pageUrl);
  assert.equal(r.imageUrl, 'https://img.example.com/photo.jpg');
});

test('로고/아이콘처럼 보이는 작은 이미지는 썸네일로 쓰지 않는다', () => {
  const html = `
    <title>제목만 있음</title>
    <img src="https://img.example.com/icon-small.png" width="30" height="30">
  `;
  const r = parseOgTags(html, pageUrl);
  assert.equal(r.imageUrl, null);
});

test('본문에 이미지가 전혀 없으면 imageUrl 없이도 제목만으로 미리보기를 돌려준다', () => {
  const html = `<title>글만 있는 글</title>`;
  const r = parseOgTags(html, pageUrl);
  assert.equal(r.title, '글만 있는 글');
  assert.equal(r.imageUrl, null);
});
