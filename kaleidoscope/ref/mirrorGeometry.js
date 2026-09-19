let scopeProg;
// 鏡の三角形（cm）。頂点が上、底辺が下
let mirrorCache = { points: 0 };
function mirrorGeometry() {
  if (mirrorCache.points === settings.points) return mirrorCache;
  const R = 2.05, al = Math.PI / settings.points;
  const A = [0, R];
  const B = [R * Math.cos(1.5 * Math.PI - al), R * Math.sin(1.5 * Math.PI - al)];
  const C = [R * Math.cos(1.5 * Math.PI + al), R * Math.sin(1.5 * Math.PI + al)];
  const cen = [(A[0] + B[0] + C[0]) / 3, (A[1] + B[1] + C[1]) / 3];
  const wall = (P, Q) => {
    let ex = Q[0] - P[0], ey = Q[1] - P[1];
    const l = Math.hypot(ex, ey); ex /= l; ey /= l;
    let nx = ey, ny = -ex;
    if ((cen[0] - P[0]) * nx + (cen[1] - P[1]) * ny > 0) { nx = -nx; ny = -ny; }
    return [nx, ny, P[0] * nx + P[1] * ny];
  };
  mirrorCache = {
    points: settings.points,
    walls: new Float32Array([...wall(A, B), ...wall(A, C), ...wall(B, C)]),
    verts: new Float32Array([...A, ...B, ...C]),
  };
  return mirrorCache;
}
// 見る方向：傾ける向きと角度（0 = 筒の奥をまっすぐ）
const TILT_MAX = 0.9;
const view = { tx: 0, ty: 0, velX: 0, velY: 0, homing: false };
function tiltBy(dx, dy) {
  view.tx += dx; view.ty += dy;
  const d = Math.hypot(view.tx, view.ty);
  if (d > TILT_MAX) { view.tx *= TILT_MAX / d; view.ty *= TILT_MAX / d; }
}
function updateView(dt, dragging) {
  if (view.homing) {
    const k = 1 - Math.exp(-dt * 6);
    view.tx -= view.tx * k; view.ty -= view.ty * k;
    if (Math.hypot(view.tx, view.ty) < 1e-3) { view.tx = view.ty = 0; view.homing = false; }
  } else if (!dragging) {
    tiltBy(view.velX * dt, view.velY * dt);
    const f = Math.exp(-dt * 4);
    view.velX *= f; view.velY *= f;
  }
}
function viewMatrix() {
  const a = Math.hypot(view.tx, view.ty);
  const s = a < 1e-6 ? 1 : Math.sin(a) / a;
  const f = [view.tx * s, view.ty * s, Math.cos(a)];   // +z = 筒の奥
  let r = [f[2], 0, -f[0]];                        // 画面の横は水平のまま
  const rl = Math.hypot(r[0], r[2]);
  r = [r[0] / rl, 0, r[2] / rl];
  const up = [f[1] * r[2] - f[2] * r[1], f[2] * r[0] - f[0] * r[2], f[0] * r[1] - f[1] * r[0]];
  return new Float32Array([...r, ...up, ...f]);
}
function renderScope(w, h) {
  const { p, u } = scopeProg;
  gl.useProgram(p);
  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, cellTex.back);
  gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, cellTex.front);
  gl.activeTexture(gl.TEXTURE0);
  gl.uniform1i(u.uBack, 0);
  gl.uniform1i(u.uFront, 1);
  const t = sim.time;
  const flow = Math.max(-1, Math.min(1, sim.fluidVel - sim.tubeVel));
