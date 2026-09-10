// README.md(전체 프로젝트 문서, 저장소 루트)를 정적 HTML로 변환한다 — 설치된 서버의
// "도움말" 바로가기가 메모장 대신 기본 브라우저로 이 결과물을 연다(목차 링크가 실제로
// 클릭되게 하려고). 이 프로젝트의 README들이 실제로 쓰는 마크다운 구성(제목, 굵게, 인라인
// 코드, 링크, 코드 펜스, 표, 순서/비순서 목록 — 중첩 포함, 체크박스 목록, 인용문)만 처리하는
// 변환기다 — 범용 마크다운 파서 라이브러리(marked 등) 없이 직접 짰다(별도 npm 의존성을
// 추가하지 않으려고). 빌드 시(build_server_installer.ps1) 매번 새로 실행되므로 README.md만
// 고치면 된다.
//
// 사용법: node build-readme-html.mjs <README.md 경로> <출력 HTML 경로>
import fs from 'node:fs';

const [, , srcPath, outPath] = process.argv;
if (!srcPath || !outPath) {
  console.error('사용법: node build-readme-html.mjs <input.md> <output.html>');
  process.exit(1);
}

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
}

function slugify(text) {
  const plain = text
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .trim()
    .toLowerCase();
  return plain.replace(/[()"'.,!?→·]/g, '').replace(/\s+/g, '-');
}

/** 굵게/인라인 코드/링크를 처리하는 인라인 렌더러. 굵게 안의 내용은 재귀적으로 다시
 * 처리해서(중첩) 그 안의 인라인 코드/링크도 정상적으로 변환되게 한다. */
function renderInline(text) {
  let out = '';
  let i = 0;
  while (i < text.length) {
    if (text.startsWith('**', i)) {
      const end = text.indexOf('**', i + 2);
      if (end !== -1) {
        out += `<strong>${renderInline(text.slice(i + 2, end))}</strong>`;
        i = end + 2;
        continue;
      }
    }
    if (text[i] === '`') {
      const end = text.indexOf('`', i + 1);
      if (end !== -1) {
        out += `<code>${escapeHtml(text.slice(i + 1, end))}</code>`;
        i = end + 1;
        continue;
      }
    }
    if (text[i] === '[') {
      const closeBracket = text.indexOf(']', i + 1);
      if (closeBracket !== -1 && text[closeBracket + 1] === '(') {
        const closeParen = text.indexOf(')', closeBracket + 2);
        if (closeParen !== -1) {
          const label = text.slice(i + 1, closeBracket);
          const href = text.slice(closeBracket + 2, closeParen);
          out += `<a href="${escapeHtml(href)}">${renderInline(label)}</a>`;
          i = closeParen + 1;
          continue;
        }
      }
    }
    out += escapeHtml(text[i]);
    i += 1;
  }
  return out;
}

const lines = fs.readFileSync(srcPath, 'utf8').split(/\r?\n/);
const bodyParts = [];
const toc = [];
let title = 'README';

/** line이 새 블록(제목/코드펜스/표/인용문/목록)의 시작인지 — 목록/단락의 "이어지는 줄"
 * 판정에 쓴다. indent 이상의 들여쓰기가 있는 목록 마커는 "이 레벨의 새 블록"이 아니라
 * 중첩 목록이므로 따로 처리하고, 여기서는 들여쓰기 없는(레벨 0) 마커만 본다. */
function isBlockStart(line) {
  return (
    line.trim() === '' ||
    /^#{1,6}\s/.test(line) ||
    line.startsWith('```') ||
    line.startsWith('|') ||
    line.startsWith('>') ||
    /^(-|\d+\.)\s/.test(line)
  );
}

/** indent칸 들여쓰기의 목록(순서/비순서, 체크박스 포함)을 파싱한다. 항목 본문 중간에 더 깊이
 * 들여쓰기된 목록 마커가 나오면 재귀적으로 중첩 목록을 만든다. */
function parseList(startIdx, indent) {
  const itemRe = new RegExp(`^ {${indent}}(-|\\d+\\.)\\s+(.*)$`);
  const deeperRe = new RegExp(`^ {${indent + 2},}(-|\\d+\\.)\\s+`);
  let i = startIdx;
  let ordered = false;
  const itemsHtml = [];

  while (i < lines.length) {
    const m = lines[i].match(itemRe);
    if (!m) break;
    ordered = m[1] !== '-';
    let itemText = m[2];
    i += 1;
    let nestedHtml = '';

    while (i < lines.length && lines[i].trim() !== '') {
      // 같은 레벨의 형제 항목이면(예: 들여쓰기 2칸의 "2. ..."가 들여쓰기 2칸 목록을 파싱하는
      // 중에 나타난 경우) 여기서 멈춰야 한다 — isBlockStart는 들여쓰기 없는 줄만 인식해서
      // 이 경우를 못 잡기 때문에 itemRe로 먼저 확인한다.
      if (itemRe.test(lines[i])) break;
      if (deeperRe.test(lines[i])) {
        const nested = parseList(i, indent + 2);
        nestedHtml += nested.html;
        i = nested.next;
        continue;
      }
      if (/^\S/.test(lines[i]) && isBlockStart(lines[i])) break;
      itemText += ' ' + lines[i].trim();
      i += 1;
    }

    const checkboxMatch = itemText.match(/^\[( |x|X)\]\s+(.*)$/);
    if (checkboxMatch) {
      const checked = checkboxMatch[1].toLowerCase() === 'x';
      itemsHtml.push(
        `<li class="checklist-item"><input type="checkbox" disabled${checked ? ' checked' : ''}> ${renderInline(checkboxMatch[2])}${nestedHtml}</li>`,
      );
    } else {
      itemsHtml.push(`<li>${renderInline(itemText)}${nestedHtml}</li>`);
    }
  }

  const tag = ordered ? 'ol' : 'ul';
  return { html: `<${tag}>${itemsHtml.join('')}</${tag}>`, next: i };
}

let i = 0;
while (i < lines.length) {
  const line = lines[i];

  if (line.trim() === '') {
    i += 1;
    continue;
  }

  // 코드 펜스
  if (line.startsWith('```')) {
    const lang = line.slice(3).trim();
    const codeLines = [];
    i += 1;
    while (i < lines.length && !lines[i].startsWith('```')) {
      codeLines.push(lines[i]);
      i += 1;
    }
    i += 1; // 닫는 ```
    const cls = lang ? ` class="language-${escapeHtml(lang)}"` : '';
    bodyParts.push(`<pre><code${cls}>${escapeHtml(codeLines.join('\n'))}</code></pre>`);
    continue;
  }

  // 제목
  const headingMatch = line.match(/^(#{1,6})\s+(.*)$/);
  if (headingMatch) {
    const level = headingMatch[1].length;
    const text = headingMatch[2].trim();
    const slug = slugify(text);
    if (level === 1) title = text.replace(/`/g, '');
    if (level === 2) toc.push({ text, slug });
    bodyParts.push(`<h${level} id="${slug}">${renderInline(text)}</h${level}>`);
    i += 1;
    continue;
  }

  // 인용문(연속된 > 줄)
  if (line.startsWith('>')) {
    const quoteLines = [];
    while (i < lines.length && lines[i].startsWith('>')) {
      quoteLines.push(lines[i].replace(/^>\s?/, ''));
      i += 1;
    }
    bodyParts.push(`<blockquote><p>${renderInline(quoteLines.join(' '))}</p></blockquote>`);
    continue;
  }

  // 표(첫 줄 | ... |, 둘째 줄 구분선 |---|---|)
  if (line.startsWith('|') && lines[i + 1] && /^\|[\s:|-]+\|$/.test(lines[i + 1].trim())) {
    const headerCells = line.split('|').slice(1, -1).map((c) => c.trim());
    i += 2;
    const rows = [];
    while (i < lines.length && lines[i].startsWith('|')) {
      rows.push(lines[i].split('|').slice(1, -1).map((c) => c.trim()));
      i += 1;
    }
    const thead = `<thead><tr>${headerCells.map((c) => `<th>${renderInline(c)}</th>`).join('')}</tr></thead>`;
    const tbody = `<tbody>${rows
      .map((r) => `<tr>${r.map((c) => `<td>${renderInline(c)}</td>`).join('')}</tr>`)
      .join('')}</tbody>`;
    bodyParts.push(`<div class="table-wrap"><table>${thead}${tbody}</table></div>`);
    continue;
  }

  // 목록(순서/비순서, 중첩·체크박스 포함) — 레벨 0(들여쓰기 없음)부터 시작.
  if (/^(-|\d+\.)\s/.test(line)) {
    const result = parseList(i, 0);
    bodyParts.push(result.html);
    i = result.next;
    continue;
  }

  // 단락 — 다음 블록 시작 전까지 이어지는 줄을 공백으로 합친다.
  {
    const paraLines = [line];
    i += 1;
    while (i < lines.length && lines[i].trim() !== '' && !isBlockStart(lines[i])) {
      paraLines.push(lines[i]);
      i += 1;
    }
    bodyParts.push(`<p>${renderInline(paraLines.join(' '))}</p>`);
  }
}

const tocHtml = toc.map((t) => `<li><a href="#${t.slug}">${renderInline(t.text)}</a></li>`).join('');

const html = `<!doctype html>
<html lang="ko"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, 'Segoe UI', sans-serif; max-width: 900px; margin: 0 auto; padding: 32px 24px 80px;
         line-height: 1.65; color: #1a1a1a; background: #fff; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e8e8; background: #1a1a1a; }
    a { color: #7aa2f7; }
    code, pre { background: #2a2a2a !important; color: #e8e8e8; }
    th, td { border-color: #444 !important; }
    blockquote { border-left-color: #555 !important; color: #bbb !important; }
    .toc { background: #242424 !important; border-color: #3a3a3a !important; }
    th { background: rgba(122, 162, 247, 0.12) !important; }
  }
  h1 { font-size: 26px; border-bottom: 2px solid #4c6ef5; padding-bottom: 10px; }
  h2 { font-size: 20px; margin-top: 40px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
  h3 { font-size: 16px; margin-top: 24px; }
  a { color: #3b5bdb; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { background: #f1f3f5; padding: 2px 6px; border-radius: 4px; font-size: 0.9em;
         font-family: Consolas, 'D2Coding', monospace; word-break: break-word; }
  pre { background: #f1f3f5; padding: 14px 16px; border-radius: 8px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  blockquote { border-left: 4px solid #4c6ef5; margin: 16px 0; padding: 4px 16px; color: #555; }
  blockquote p { margin: 4px 0; }
  .table-wrap { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; margin: 12px 0; }
  th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; vertical-align: top; font-size: 0.95em; }
  th { background: rgba(76, 110, 245, 0.08); }
  ul, ol { padding-left: 22px; }
  li { margin: 4px 0; }
  li > ul, li > ol { margin-top: 4px; }
  .checklist-item { list-style: none; margin-left: -22px; }
  .toc { background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 10px; padding: 16px 20px; margin: 20px 0; }
  .toc-title { font-weight: bold; margin-bottom: 8px; }
  .toc ul { margin: 0; padding-left: 20px; columns: 2; }
</style></head>
<body>
${bodyParts[0] ?? ''}
<div class="toc"><div class="toc-title">목차</div><ul>${tocHtml}</ul></div>
${bodyParts.slice(1).join('\n')}
</body></html>`;

fs.writeFileSync(outPath, html, 'utf8');
console.log(`변환 완료: ${outPath} (${toc.length}개 섹션)`);
