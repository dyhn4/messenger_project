/*
 * TangoTalk 초보자용 도움말 — 작은 보조 스크립트(외부 라이브러리 없음).
 *  1) 목차: 지금 읽는 부분을 목차에서 강조하고, 좁은 화면에서는 목차 상자를 접어 둔다
 *     (화면이 다시 넓어지면 펼친다).
 *  2) 스크린샷: 누르면 화면 가득 크게 보여준다(휴대폰 폭에서는 브라우저가 그림을 직접 열어
 *     손가락으로 확대할 수 있게 그대로 둔다).
 *  3) 인쇄: 접혀 있는 목록(자주 묻는 질문 등)을 펼쳐서 인쇄한다.
 * 스크립트가 없어도 모든 내용은 그대로 보인다 — 그림 링크는 원본 그림을 연다.
 */
(function () {
  'use strict';

  var narrow = window.matchMedia('(max-width: 960px)');

  // ── 1) 목차 ────────────────────────────────────────────
  var tocBox = document.querySelector('.toc details');
  if (tocBox && narrow.matches) tocBox.removeAttribute('open');

  // 화면 폭이 바뀌면(태블릿 회전·창 넓히기) 목차도 맞춰 준다 — 넓은 화면에는 "펼치기" 표시가
  // 없어서, 접힌 채로 두면 '목차' 글자만 남고 펼칠 수 있다는 것을 알 수 없다.
  function onNarrowChange(e) {
    if (!tocBox) return;
    if (e.matches) tocBox.removeAttribute('open');
    else tocBox.setAttribute('open', '');
  }
  if (narrow.addEventListener) narrow.addEventListener('change', onNarrowChange);
  else if (narrow.addListener) narrow.addListener(onNarrowChange); // 오래된 Safari·Edge

  var tocLinks = Array.prototype.slice.call(document.querySelectorAll('.toc a[href^="#"]'));
  var targets = tocLinks
    .map(function (a) {
      var el = document.getElementById(decodeURIComponent(a.getAttribute('href').slice(1)));
      return el ? { link: a, el: el } : null;
    })
    .filter(Boolean);

  function highlight() {
    if (!targets.length) return;
    // 머리글 바로 아래(화면 위쪽 30%)를 지난 마지막 제목을 "지금 읽는 곳"으로 본다.
    var line = window.innerHeight * 0.3;
    var current = targets[0];
    for (var i = 0; i < targets.length; i++) {
      if (targets[i].el.getBoundingClientRect().top - line <= 0) current = targets[i];
    }
    // 맨 아래까지 내렸으면 마지막 항목
    if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4) {
      current = targets[targets.length - 1];
    }
    targets.forEach(function (t) {
      var on = t === current;
      t.link.classList.toggle('is-active', on);
      if (on) t.link.setAttribute('aria-current', 'location');
      else t.link.removeAttribute('aria-current');
    });
    // 긴 목차에서도 강조된 항목이 보이게(넓은 화면의 따라오는 목차만)
    var toc = document.querySelector('.toc');
    if (toc && !narrow.matches && current) {
      var r = current.link.getBoundingClientRect();
      var box = toc.getBoundingClientRect();
      if (r.top < box.top || r.bottom > box.bottom) {
        toc.scrollTop += r.top - box.top - box.height / 3;
      }
    }
  }

  var ticking = false;
  window.addEventListener(
    'scroll',
    function () {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(function () {
        ticking = false;
        highlight();
      });
    },
    { passive: true }
  );
  window.addEventListener('resize', highlight);
  highlight();

  // 좁은 화면에서 목차 항목을 누르면 목차를 접어서 본문이 바로 보이게
  tocLinks.forEach(function (a) {
    a.addEventListener('click', function () {
      if (tocBox && narrow.matches) tocBox.removeAttribute('open');
    });
  });

  // ── 2) 스크린샷 크게 보기 ─────────────────────────────
  var lastFocus = null;
  var overlay = null;

  function closeZoom() {
    if (!overlay) return;
    overlay.remove();
    overlay = null;
    document.body.classList.remove('lightbox-open');
    document.removeEventListener('keydown', onKey);
    if (lastFocus) lastFocus.focus();
  }

  function onKey(e) {
    if (e.key === 'Escape') closeZoom();
  }

  function openZoom(link) {
    var img = link.querySelector('img');
    var figure = link.closest('figure');
    var caption = figure && figure.querySelector('figcaption');

    overlay = document.createElement('div');
    overlay.className = 'lightbox';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-label', '크게 보기');

    var big = document.createElement('img');
    big.src = link.getAttribute('href');
    big.alt = img ? img.alt : '';
    overlay.appendChild(big);

    if (caption) {
      var cap = document.createElement('p');
      cap.className = 'lightbox-caption';
      cap.textContent = caption.textContent;
      overlay.appendChild(cap);
    }

    var close = document.createElement('button');
    close.type = 'button';
    close.className = 'lightbox-close';
    close.setAttribute('aria-label', '닫기');
    close.textContent = '×';
    overlay.appendChild(close);

    overlay.addEventListener('click', closeZoom);
    document.addEventListener('keydown', onKey);
    document.body.appendChild(overlay);
    document.body.classList.add('lightbox-open');
    lastFocus = link;
    close.focus();
  }

  document.addEventListener('click', function (e) {
    var link = e.target.closest && e.target.closest('a.shot-frame');
    if (!link) return;
    // 휴대폰 폭에서는 그림 자체를 열어 두 손가락 확대를 쓰게 한다.
    if (window.innerWidth < 640) return;
    if (e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    openZoom(link);
  });

  // ── 3) 인쇄할 때는 접힌 내용을 펼친다 ──────────────────
  var reopened = [];
  window.addEventListener('beforeprint', function () {
    reopened = Array.prototype.slice.call(document.querySelectorAll('details:not([open])'));
    reopened.forEach(function (d) {
      d.setAttribute('open', '');
    });
  });
  window.addEventListener('afterprint', function () {
    reopened.forEach(function (d) {
      d.removeAttribute('open');
    });
    reopened = [];
  });
})();
