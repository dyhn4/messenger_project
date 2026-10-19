import ExcelJS from 'exceljs';
import { Parser } from 'htmlparser2';
import { decodeText, parseCsv, statementFileKind } from './cardRules.js';

/**
 * 올린 표 파일(엑셀 .xlsx·CSV·엑셀로 이름만 바꾼 HTML 표) → 줄들(줄마다 열 순서의 값 — 엑셀의 날짜는 Date, 숫자는 number). 급여대장 가져오기
 * (payroll.js)와 법인카드 이용내역 가져오기(corporateCards.js)가 쓴다. 국내 카드사 홈페이지의 "엑셀 저장"은 옛 이진 .xls이거나 HTML 표인 경우가
 * 많다 — HTML 표는 읽고, 옛 .xls는 엑셀에서 .xlsx로 다시 저장하라고 알린다. CSV·HTML은 UTF-8이 아니면 EUC-KR로 읽는다.
 * `{ rows }` | `{ error }`. 시트가 여러 장이면 [sheetName]이 있으면 그 시트, 없으면 값이 가장 많은 시트.
 */
export async function readSheetRows(buffer, { sheetName = null } = {}) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) return { error: '파일이 비어 있습니다.' };
  const kind = statementFileKind(buffer);
  if (kind === 'xls') return { error: '옛 엑셀 형식(.xls)은 읽지 못합니다. 엑셀에서 "다른 이름으로 저장 → Excel 통합 문서(.xlsx)"나 CSV로 저장해 올리세요.' };
  if (kind === 'csv') return { rows: parseCsv(decodeText(buffer)) };
  if (kind === 'html') return { rows: htmlTableRows(decodeText(buffer)) };
  const wb = new ExcelJS.Workbook();
  try {
    await wb.xlsx.load(buffer);
  } catch {
    return { error: '엑셀 파일(.xlsx)을 읽지 못했습니다.' };
  }
  const sheets = wb.worksheets ?? [];
  if (!sheets.length) return { error: '시트가 없습니다.' };
  const picked = (sheetName && wb.getWorksheet(sheetName)) || sheets.reduce((best, ws) => (ws.actualRowCount > (best?.actualRowCount ?? -1) ? ws : best), null);
  const rows = [];
  picked.eachRow({ includeEmpty: true }, (row) => {
    const values = Array.isArray(row.values) ? row.values.slice(1) : [];
    rows.push(Array.from(values, (v) => (v === undefined ? null : v)));
  });
  return { rows };
}

/** HTML 글의 표들 → 줄들(<tr>마다 <td>·<th>의 글자). 표가 여럿이면 이어 붙인다(머리 줄은 읽는 쪽이 찾는다). */
export function htmlTableRows(html) {
  const rows = [];
  let row = null;
  let cell = null;
  const parser = new Parser(
    {
      onopentag(name) {
        if (name === 'tr') row = [];
        else if ((name === 'td' || name === 'th') && row) cell = '';
        else if (name === 'br' && cell !== null) cell += ' ';
      },
      ontext(text) {
        if (cell !== null) cell += text;
      },
      onclosetag(name) {
        if ((name === 'td' || name === 'th') && row && cell !== null) {
          row.push(cell.replace(/&nbsp;| /g, ' ').replace(/\s+/g, ' ').trim());
          cell = null;
        } else if (name === 'tr' && row) {
          if (row.some((c) => c !== '')) rows.push(row);
          row = null;
        }
      },
    },
    { decodeEntities: true },
  );
  parser.write(html);
  parser.end();
  return rows;
}
