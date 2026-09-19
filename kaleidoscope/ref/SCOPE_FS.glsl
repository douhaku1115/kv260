const SCOPE_FS = `#version 300 es
precision highp float;
out vec4 o;
uniform sampler2D uBack, uFront;
uniform vec2 uRes, uPar;
uniform mat3 uView;
uniform float uTime, uMirror, uFocal;
uniform float uMaxRefl;         // 最大反射回数（画質）
uniform float uLoss;            // 1回の反射で残る光の割合（「遠くの暗さ」で変わる）
uniform vec3 uWall[3];      // 鏡の面：外向き法線 xy と、法線方向の位置（cm）。[0][1]=長い鏡, [2]=底辺
uniform vec2 uVert[3];      // 三角形の頂点（cm）
${GLSL_COMMON}
const float TUBE_R = 2.25;      // 筒の内側の半径 = セルの半径
const float Z_MIRROR = 0.3;     // のぞき穴から鏡の手前の端まで
const float Z_CELL = 12.2;      // のぞき穴からセルの手前の層まで
const float CELL_GAP = 0.35;    // セルの手前の層と奥の層の距離

void main(){
  vec2 sp = (gl_FragCoord.xy - 0.5 * uRes) / uRes.y;
  vec3 rd = normalize(uView * vec3(sp, uFocal));
  vec2 slope = rd.xy / max(rd.z, 1e-3);          // 奥へ1cm進むごとの断面での移動
  float pw = length(fwidth(slope)) * Z_CELL;       // 1画素がセル上で占める大きさ（cm）

  vec2 p = slope * Z_MIRROR;                        // 鏡の手前の端での位置
  bool black = rd.z < 1e-3;
  for (int w = 0; w < 3; w++) if (dot(p, uWall[w].xy) > uWall[w].z) black = true;   // 鏡の外 = 筒の縁

  float sl = length(slope);
  vec2 dir = sl > 1e-6 ? slope / sl : vec2(0.0, 1.0);
  float remain = sl * (Z_CELL - Z_MIRROR);
  float n = 0.0, seam = 1.0;
  for (int i = 0; i < 128; i++) {
    if (black) break;
    float tb = 1e9; int wi = -1;
    for (int w = 0; w < 3; w++) {
      float dn = dot(dir, uWall[w].xy);
      if (dn > 1e-7) { float t = max((uWall[w].z - dot(p, uWall[w].xy)) / dn, 0.0); if (t < tb) { tb = t; wi = w; } }
    }
    if (wi < 0 || tb >= remain) { p += dir * remain; break; }
    p += dir * tb;
    remain -= tb;
    if (wi == 2 && uMirror < 2.5) { black = true; break; }
    float dv = min(min(length(p - uVert[0]), length(p - uVert[1])), length(p - uVert[2]));
    seam *= mix(0.35, 1.0, smoothstep(0.0, 0.03 + 0.004 * n, dv));   // 鏡の合わせ目
    dir = reflect(dir, uWall[wi].xy);
    n += 1.0;
    if (n >= uMaxRefl) break;
  }

  vec2 c = p / TUBE_R;
  vec2 cB = (p + dir * sl * CELL_GAP) / TUBE_R;    // 奥の層は鏡の先をまっすぐ進んだ位置
  c += 0.003 * vec2(sin(c.y * 9.0 + uTime * 0.6), cos(c.x * 8.0 - uTime * 0.5));   // オイル越しのゆらぎ
  float lod = log2(max(pw / TUBE_R * 512.0, 1.0)) + n * 0.12;
  vec4 F = textureLod(uFront, (c + uPar) * 0.5 + 0.5, lod);
  float sh = textureLod(uFront, (c + uPar + vec2(0.012, -0.016)) * 0.5 + 0.5, lod + 2.0).a;
  vec3 B = textureLod(uBack, (cB - uPar * 0.7) * 0.5 + 0.5, lod + 0.4).rgb;
  B *= 1.0 - 0.5 * sh;
  vec3 col = F.rgb + B * (1.0 - F.a);
  col *= pow(uLoss, n) * seam;
  if (black) col = vec3(0.01, 0.009, 0.013);
  col *= 1.0 - 0.3 * dot(sp, sp);
  o = vec4(col + dither(), 1.0);
