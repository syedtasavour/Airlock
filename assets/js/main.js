/* ============================================================
   airlock · main.js
   Scroll-reveal, sticky nav, mobile menu, terminal caret,
   active-link spy, and hero parallax.
   ============================================================ */
(function () {
  'use strict';

  /* 1. Scroll-reveal via IntersectionObserver */
  var els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window)) {
    els.forEach(function (e) { e.classList.add('in'); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });
    els.forEach(function (e) { io.observe(e); });
  }

  /* 2. Sticky nav background on scroll */
  var nav = document.getElementById('nav');
  function onScroll() { if (nav) nav.classList.toggle('scrolled', window.scrollY > 30); }
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  /* 3. Mobile menu toggle */
  var burger = document.getElementById('burger');
  var links = document.getElementById('navLinks');
  if (burger && links) {
    burger.addEventListener('click', function () { links.classList.toggle('open'); });
    links.querySelectorAll('a').forEach(function (a) {
      a.addEventListener('click', function () { links.classList.remove('open'); });
    });
  }

  /* 4. Blinking caret in the terminal */
  var caret = document.getElementById('cursor');
  if (caret) {
    var on = true;
    setInterval(function () {
      on = !on;
      caret.style.borderRightColor = on ? 'transparent' : 'var(--safe)';
    }, 560);
  }

  /* 5. Active-section nav spy */
  var navAnchors = links ? Array.prototype.slice.call(links.querySelectorAll('a')) : [];
  var sections = navAnchors
    .map(function (a) { var id = a.getAttribute('href'); return id && id[0] === '#' ? document.querySelector(id) : null; })
    .filter(Boolean);
  if (sections.length && 'IntersectionObserver' in window) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          navAnchors.forEach(function (a) {
            a.style.color = a.getAttribute('href') === '#' + e.target.id ? 'var(--ink)' : '';
          });
        }
      });
    }, { rootMargin: '-45% 0px -50% 0px' });
    sections.forEach(function (s) { spy.observe(s); });
  }

  /* 6. Subtle hero parallax */
  var ch = document.querySelector('.chamber');
  if (ch && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    window.addEventListener('scroll', function () {
      var y = window.scrollY;
      if (y < 900) ch.style.transform = 'translateY(' + (y * 0.06) + 'px)';
    }, { passive: true });
  }

  /* 7. Current year in footer */
  var yr = document.getElementById('year');
  if (yr) yr.textContent = new Date().getFullYear();
})();
