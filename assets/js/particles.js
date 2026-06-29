/* ============================================================
   airlock · particles.js
   The "airlock field" — a lightweight connection-graph canvas.
   DPR-aware, density-scaled, pauses when the tab is hidden.
   ============================================================ */
(function () {
  'use strict';
  var cv = document.getElementById('bgCanvas');
  if (!cv || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var ctx = cv.getContext('2d');
  var w, h, pts, raf;
  var COLORS = ['45,214,115', '52,214,255', '155,123,255'];

  function size() {
    var dpr = window.devicePixelRatio || 1;
    w = cv.width = innerWidth * dpr;
    h = cv.height = innerHeight * dpr;
    cv.style.width = innerWidth + 'px';
    cv.style.height = innerHeight + 'px';
    var density = Math.min(70, Math.floor(innerWidth * innerHeight / 26000));
    pts = [];
    for (var i = 0; i < density; i++) {
      pts.push({
        x: Math.random() * w, y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.22 * dpr,
        vy: (Math.random() - 0.5) * 0.22 * dpr,
        r: (Math.random() * 1.6 + 0.6) * dpr,
        c: COLORS[Math.floor(Math.random() * COLORS.length)]
      });
    }
  }

  function draw() {
    var dpr = window.devicePixelRatio || 1;
    ctx.clearRect(0, 0, w, h);
    var LINK = 130 * dpr;
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      p.x += p.vx; p.y += p.vy;
      if (p.x < 0 || p.x > w) p.vx *= -1;
      if (p.y < 0 || p.y > h) p.vy *= -1;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(' + p.c + ',.55)';
      ctx.fill();
      for (var j = i + 1; j < pts.length; j++) {
        var q = pts[j], dx = p.x - q.x, dy = p.y - q.y, d = Math.hypot(dx, dy);
        if (d < LINK) {
          ctx.beginPath();
          ctx.moveTo(p.x, p.y); ctx.lineTo(q.x, q.y);
          ctx.strokeStyle = 'rgba(' + p.c + ',' + (0.16 * (1 - d / LINK)) + ')';
          ctx.lineWidth = dpr * 0.6;
          ctx.stroke();
        }
      }
    }
    raf = requestAnimationFrame(draw);
  }

  size(); draw();

  var t;
  addEventListener('resize', function () {
    clearTimeout(t);
    t = setTimeout(function () { cancelAnimationFrame(raf); size(); draw(); }, 180);
  });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) cancelAnimationFrame(raf); else draw();
  });
})();
