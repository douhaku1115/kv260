const PART_VS = `#version 300 es
layout(location=0) in vec2 aCorner;
layout(location=1) in vec4 aA;   // x y r rot
layout(location=2) in vec4 aB;   // type seed z -
layout(location=3) in vec4 aC;   // rgb -
uniform float uSize;             // ピースの大きさの倍率（筒をのぞく=1、中に入る=設定の「ピースの大きさ」）
out vec2 vQ; flat out vec4 vB; flat out vec4 vC; flat out float vRot;
void main(){
  float z = aB.z;
  float r = aA.z * uSize * (0.85 + 0.3 * z);
  float pad = (aB.x > 1.5 && aB.x < 2.5) ? 2.6 : 1.2;
  vQ = aCorner * pad;
  vB = aB; vC = aC; vRot = aA.w;
  gl_Position = vec4(aA.xy + aCorner * r * pad, 0.0, 1.0);
}`;

const PART_FS = `#version 300 es
precision highp float;
in vec2 vQ; flat in vec4 vB; flat in vec4 vC; flat in float vRot;
uniform float uTime;
out vec4 o;
${GLSL_COMMON}
float ngon(vec2 p, float n){ float b = PI2 / n; float a = atan(p.y, p.x); float s = floor(a / b + 0.5) * b; return cos(a - s) * length(p); }
float star(vec2 p){ float a = atan(p.y, p.x); float k = 0.5 + 0.5 * cos(a * 5.0); return length(p) / (0.45 + 0.55 * k * k); }
void main(){
  int type = int(vB.x + 0.5);
  float seed = vB.y, z = vB.z;
  vec2 q = rot(vRot) * vQ;
  float e = mix(0.1, 0.025, z);                  // 奥ほどぼける
  vec3 L = normalize(vec3(-0.45, 0.55, 0.7));
  vec3 c = vC.rgb;
  vec3 rgb; float a;
  float depthShade = mix(0.65, 1.0, z);

  if (type == 0) {                               // ビーズ
    float d = length(vQ);
    a = 1.0 - smoothstep(1.0 - e, 1.0 + e, d);
    vec2 nq = vQ / max(d, 1.0);
    vec3 n = vec3(nq, sqrt(max(0.0, 1.0 - dot(nq, nq))));
    float dif = max(dot(n, L), 0.0);
    float sp = pow(max(dot(reflect(-L, n), vec3(0, 0, 1)), 0.0), 40.0);
    float through = smoothstep(-0.2, 0.9, dot(nq, -L.xy));
    rgb = c * (0.3 + 0.55 * dif) + c * through * 0.7 + vec3(1.0) * sp * 1.3;
  } else if (type == 1) {                        // 色ガラス
    vec2 p = q * vec2(1.0 + 0.45 * seed, 1.0 - 0.2 * seed);
    float v = ngon(p, 3.0 + floor(seed * 2.999));
    const float ap = 0.72;
    a = 1.0 - smoothstep(ap - e, ap + e, v);
    float edge = smoothstep(ap - 0.18, ap, v);
    float face = 0.5 + 0.5 * dot(normalize(p + 1e-4), -L.xy) * min(length(p) / ap, 1.0);
    rgb = c * (0.8 + 0.6 * face) + vec3(1.0) * edge * 0.35;
    a *= 0.72 + 0.25 * edge;
  } else if (type == 2) {                        // ラメ：向きでまたたく
    float v = ngon(q, 6.0);
    float cov = 1.0 - smoothstep(0.85 - e * 2.0, 0.85 + e * 2.0, v);
    float sp = pow(0.5 + 0.5 * sin(vRot * 4.0 + seed * 60.0 + uTime * (0.3 + seed * 0.6)), 14.0);
    float lq = length(vQ);
    float glow = sp * exp(-lq * 1.5) * 0.9;
    float flare = sp * (exp(-abs(vQ.x) * 12.0) + exp(-abs(vQ.y) * 12.0)) * exp(-lq * 0.9) * 0.6;
    rgb = (c * 0.65 + vec3(1.0) * sp * 1.4) * cov + (c * 0.5 + 0.5) * (glow + flare);
    a = clamp(cov * 0.9 + glow + flare, 0.0, 1.0);
    o = vec4(rgb * depthShade, a);
    return;
  } else if (type == 3) {                        // 星
    float v = star(q);
    a = 1.0 - smoothstep(0.92 - e, 0.92 + e, v);
    float sh = 0.5 + 0.5 * sin(dot(q, vec2(2.3, 1.7)) + vRot * 2.0 + seed * 9.0);
    rgb = c * (0.5 + 0.6 * sh) + vec3(1.0, 0.97, 0.85) * pow(sh, 10.0) * 0.9;
  } else if (type == 5) {                        // 天然石
    float an = atan(q.y, q.x);
    float rad = 0.84 + 0.08 * sin(an * 3.0 + seed * 20.0) + 0.05 * sin(an * 5.0 + seed * 37.0);
    float d = length(q) / rad;
    a = 1.0 - smoothstep(1.0 - e, 1.0 + e, d);
    vec2 nq = vQ / rad;
    float l2 = dot(nq, nq);
    if (l2 > 1.0) nq /= sqrt(l2);
    vec3 n = vec3(nq, sqrt(max(0.0, 1.0 - dot(nq, nq))));
    float dif = max(dot(n, L), 0.0);
    float band = sin(dot(q, vec2(cos(seed * 6.0), sin(seed * 6.0))) * 9.0
               + sin(q.x * 4.0 + seed * 11.0) * sin(q.y * 5.0 - seed * 7.0) * 2.5 + seed * 30.0);
    vec3 base = mix(c * 0.55, mix(c, vec3(1.0), 0.35), smoothstep(-0.3, 0.9, band));
    rgb = base * (0.4 + 0.8 * dif) + vec3(1.0) * pow(max(dot(reflect(-L, n), vec3(0, 0, 1)), 0.0), 24.0) * 0.5;
  } else if (type == 6) {                        // 棒：細いガラス棒
    float d = length(vec2(max(abs(q.x) - 0.8, 0.0), q.y)) - 0.16;
    a = 1.0 - smoothstep(-e * 0.4, e * 0.4, d);
    float cy = clamp(q.y / 0.16, -1.0, 1.0);
    float shade = sqrt(max(0.0, 1.0 - cy * cy));
    float hl = pow(max(0.0, 1.0 - abs(cy + 0.4) * 2.5), 3.0);
    rgb = c * (0.55 + 0.7 * shade) + vec3(1.0) * hl * 0.8;
    a *= 0.95;
  } else if (type == 7) {                        // 丸い塊：半透明
    float an = atan(q.y, q.x);
    float rad = 0.82 + 0.1 * sin(an * 3.0 + seed * 17.0) + 0.06 * sin(an * 5.0 + seed * 29.0);
    float d = length(q) / rad;
    a = 1.0 - smoothstep(1.0 - e, 1.0 + e, d);
    float core = clamp(1.0 - d * d, 0.0, 1.0);
    rgb = c * (0.7 + 0.8 * core) + vec3(1.0) * exp(-length(vQ - vec2(-0.3, 0.35)) * 6.0) * 0.4;
    a *= 0.55 + 0.4 * core;
  } else if (type == 8) {                        // 三日月・羽の形
    float d1 = length(q) - 0.9;
    float d2 = length(q - vec2(0.42, 0.18)) - 0.74;
    float d = max(d1, -d2);
    a = 1.0 - smoothstep(-e, e, d);
    float g = clamp(-d / 0.22, 0.0, 1.0);
    rgb = mix(c * 0.7, c * 1.2, g);
    a *= 0.95;
  } else {                                       // 気泡
    float d = length(vQ);
    float ring = smoothstep(0.7, 0.97, d) * (1.0 - smoothstep(0.97, 1.03 + e, d));
    float spot = exp(-length(vQ - vec2(-0.38, 0.4)) * 9.0);
    a = clamp(ring * 0.5 + spot * 0.9, 0.0, 1.0);
    rgb = vec3(0.9, 0.95, 1.0) * (ring * 0.6 + spot * 1.2) / max(a, 1e-3);
  }
  rgb *= depthShade;
  o = vec4(rgb * a, a);
}`;

// 暗いオイルの地
const OIL_FS = `#version 300 es
precision highp float;
in vec2 vUv; out vec4 o;
uniform float uTime;
void main(){
  vec2 c = vUv * 2.0 - 1.0;
  float r = length(c);
  vec3 base = mix(vec3(0.055, 0.045, 0.08), vec3(0.02, 0.018, 0.03), smoothstep(0.0, 1.0, r));
  float w = 0.5 + 0.5 * sin(c.x * 3.1 + sin(c.y * 2.3 + uTime * 0.15) * 1.7 + uTime * 0.1);
  o = vec4(base * (0.8 + 0.4 * w), 1.0);
}`;

