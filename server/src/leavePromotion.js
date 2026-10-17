import { addDaysKey, addMonthsKey, isDateKey, leavePeriod } from './annualLeave.js';

/**
 * 연차 사용 촉진(근로기준법 제61조)의 **순수 규칙** — 언제 1차·2차 촉진을 해야 하는지, 받은 사람이 내는 사용 계획과 회사가 정하는 날 검사.
 * DB는 groupwareWork.js. `node --test`로 시험한다(test/groupwareWork.test.js).
 *
 * 1년 이상 근무(제61조 제1항):
 *  1차 — 연차 기간이 끝나기 6개월 전을 기준으로 10일 안에, 쓰지 않은 연차 일수를 알리고 쓸 시기를 정해 알려 달라고 서면으로 요구.
 *        받은 사람은 그로부터 10일 안에 쓸 시기를 정해 알린다.
 *  2차 — 그 10일 안에 시기를 알리지 않으면, 끝나기 2개월 전까지 회사가 쓸 시기를 정해 서면으로 알린다.
 * 1년 미만(입사 첫해 — 제61조 제2항): 1차는 끝나기 3개월 전 기준 10일 안(받은 사람은 10일 안에), 2차는 끝나기 1개월 전까지.
 * (1년 미만 중 1차 뒤에 새로 생긴 연차의 1개월 전·10일 전 절차는 따로 다루지 않는다 — 관리자가 같은 화면에서 한 번 더 보낸다.)
 *
 * 앱 알림·결재 화면으로 알리고 받은 사람이 확인(읽음)한 시각을 남긴다 — 회사가 전자문서를 서면으로 인정하는지는 노무 담당과 확인할 것.
 */

/** 받은 사람이 사용 계획을 낼 기간(일). */
export const PLAN_RESPONSE_DAYS = 10;
/** 1차 촉진을 할 기간(만료 몇 달 전을 기준으로 며칠 안). */
export const FIRST_NOTICE_DAYS = 10;
export const PROMOTION_MESSAGE_MAX = 500;

/**
 * 그 사람의 이번 연차 기간 촉진 일정 — `{ periodStart, periodEnd(다음 기간 시작 — 그날은 안 듦), expiry(마지막 날), firstYear,
 * firstStart, firstEnd(1차를 해야 하는 10일 — 끝 포함), secondDeadline(2차 마감 — 그날까지) }`. 입사일이 없으면 null.
 */
export function promotionSchedule(hireDate, today) {
  const period = leavePeriod(hireDate, today);
  if (!period) return null;
  const expiry = addDaysKey(period.end, -1);
  const firstYear = period.year === 0;
  const firstStart = addMonthsKey(expiry, firstYear ? -3 : -6);
  return {
    periodStart: period.start,
    periodEnd: period.end,
    expiry,
    firstYear,
    firstStart,
    firstEnd: addDaysKey(firstStart, FIRST_NOTICE_DAYS - 1),
    secondDeadline: addMonthsKey(expiry, firstYear ? -1 : -2),
  };
}

/**
 * 지금 해야 할 일 — 'first'(1차 기간이다) | 'awaiting'(1차를 보냈고 계획을 기다린다) | 'second'(1차 뒤 계획을 안 냈다 — 2차 마감 전) |
 * 'done'(계획을 냈거나 2차를 보냈다) | 'missed'(1차 기간을 놓쳤다 — 법정 촉진으로 인정받기 어렵다) | 'upcoming'(아직 이르다) |
 * 'none'(남은 연차 없음).
 * [notices]는 이 기간에 보낸 통지들 `{ stage, deadline, planDates }`.
 */
export function promotionStage({ schedule, today, remainingHalfDays, notices = [] }) {
  if (!schedule || remainingHalfDays <= 0) return 'none';
  const first = notices.find((n) => n.stage === 1);
  const second = notices.find((n) => n.stage === 2);
  if (second) return 'done';
  if (first) {
    if (Array.isArray(first.planDates) && first.planDates.length > 0) return 'done';
    if (today <= first.deadline) return 'awaiting';
    return today <= schedule.secondDeadline ? 'second' : 'missed';
  }
  if (today < schedule.firstStart) return 'upcoming';
  if (today <= schedule.firstEnd) return 'first';
  return today <= schedule.expiry ? 'missed' : 'none';
}

/**
 * 날짜 목록(사용 계획·회사가 정한 날) 검사 — 'YYYY-MM-DD', [from]~[expiry] 안, 겹치지 않게, [maxDays]일까지(남은 연차보다 많이 고를 수
 * 없다). 하루 단위(반차는 따로 신청). `{ dates }`(정렬) | `{ error }`.
 */
export function parseLeaveDates(input, { from, expiry, maxDays }) {
  if (!Array.isArray(input) || input.length === 0) return { error: '쓸 날을 하나 이상 고르세요.' };
  const dates = [...new Set(input)].sort();
  if (dates.length !== input.length) return { error: '같은 날을 두 번 골랐습니다.' };
  if (!dates.every(isDateKey)) return { error: '날짜를 확인하세요.' };
  if (dates[0] < from || dates[dates.length - 1] > expiry) return { error: `${from}부터 ${expiry}까지의 날만 고를 수 있습니다.` };
  if (dates.length > maxDays) return { error: `남은 연차(${maxDays}일)보다 많이 고를 수 없습니다.` };
  return { dates };
}
