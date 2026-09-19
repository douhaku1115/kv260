function stepSim(dt) {
  const s = sim;
  if (s.dragging) {
    if (performance.now() - s.lastTurn > 60) s.tubeVel *= Math.exp(-dt * 12);
  } else {
    const target = settings.autoRotate * 0.6 + s.keyTurn;
    s.tubeVel += (target - s.tubeVel) * (1 - Math.exp(-dt * (s.keyTurn ? 4 : 1.2)));
    s.tubeAngle += s.tubeVel * dt;
  }
  const thin = Math.pow(2.5, (0.5 - settings.viscosity) * 2);
  s.fluidVel += (s.tubeVel - s.fluidVel) * (1 - Math.exp(-dt * thin / 2.2));
  const wRel = s.fluidVel - s.tubeVel;
  const [ux, uy] = upInCell();
  const gx = -ux, gy = -uy;
  const k = 1 - Math.exp(-dt * 6 * thin);
  const t = s.time;

  const P = s.parts;
  for (const p of P) {
    // 筒との回転差による渦 ＋ ゆるい対流（ラメほど流されやすい） ＋ 沈降
    const drift = p.type === T.GLITTER ? 0.09 : 0.03;
    const tx = -wRel * p.y + drift * Math.sin(p.y * 3.1 + t * 0.31) + gx * p.sink * thin + (Math.random() - 0.5) * 0.02;
    const ty = wRel * p.x + drift * Math.cos(p.x * 2.7 - t * 0.27) + gy * p.sink * thin + (Math.random() - 0.5) * 0.02;
    p.vx += (tx - p.vx) * k;
    p.vy += (ty - p.vy) * k;
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    if (p.type !== T.BUBBLE) {
      p.vz += ((Math.random() - 0.5) * 0.5 - p.vz * 1.5) * dt;
      p.z += p.vz * dt * 0.15;
      if (p.z < 0.02) { p.z = 0.02; p.vz = Math.abs(p.vz); }
      if (p.z > 0.98) { p.z = 0.98; p.vz = -Math.abs(p.vz); }
    }
    const speed = Math.hypot(p.vx, p.vy);
    p.spin += (wRel * 0.8 - p.spin) * k;
    p.rot += (p.spin + speed * 0.3 / p.r * Math.sign(p.vx * gy - p.vy * gx || 1)) * dt;
  }

  // 押し合い（ラメは小さいので省略）。奥行きが離れていれば重なってよい
  const solid = P.filter(p => p.cr > 0);
  for (let it = 0; it < 2; it++) {
    for (let i = 0; i < solid.length; i++) {
      const a = solid[i];
      for (let j = i + 1; j < solid.length; j++) {
        const b = solid[j];
        if (Math.abs(a.z - b.z) > 0.45) continue;
        const dx = b.x - a.x, dy = b.y - a.y;
        const minD = a.cr + b.cr;
        const d2 = dx * dx + dy * dy;
        if (d2 >= minD * minD || d2 === 0) continue;
        const d = Math.sqrt(d2);
        const ov = (minD - d) / d;
        const ma = a.cr * a.cr, mb = b.cr * b.cr, m = ma + mb;
        a.x -= dx * ov * mb / m; a.y -= dy * ov * mb / m;
        b.x += dx * ov * ma / m; b.y += dy * ov * ma / m;
      }
    }
  }
  for (const p of P) {
    const d = Math.hypot(p.x, p.y), lim = 0.985 - Math.max(p.cr, p.r * 0.5);
    if (d > lim) { p.x *= lim / d; p.y *= lim / d; }
  }
}
