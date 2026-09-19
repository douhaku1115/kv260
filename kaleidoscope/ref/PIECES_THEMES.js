const PIECES = [
  { key: 'glass',    type: T.GLASS,    name: '色ガラス', max: 60,  rMin: 0.09,  rMax: 0.18,  sink: 0.15, cr: 0.85 },
  { key: 'rod',      type: T.ROD,      name: '棒',       max: 40,  rMin: 0.12,  rMax: 0.22,  sink: 0.20, cr: 0.45 },
  { key: 'blob',     type: T.BLOB,     name: '丸い塊',   max: 20,  rMin: 0.09,  rMax: 0.15,  sink: 0.12, cr: 0.9 },
  { key: 'crescent', type: T.CRESCENT, name: '三日月',   max: 20,  rMin: 0.11,  rMax: 0.19,  sink: 0.10, cr: 0.7 },
  { key: 'bead',     type: T.BEAD,     name: 'ビーズ',   max: 40,  rMin: 0.04,  rMax: 0.07,  sink: 0.28, cr: 1 },
  { key: 'stone',    type: T.STONE,    name: '天然石',   max: 20,  rMin: 0.06,  rMax: 0.10,  sink: 0.34, cr: 1 },
  { key: 'star',     type: T.STAR,     name: '星',       max: 20,  rMin: 0.06,  rMax: 0.10,  sink: 0.10, cr: 0.8 },
  { key: 'glitter',  type: T.GLITTER,  name: 'ラメ',     max: 400, rMin: 0.009, rMax: 0.018, sink: 0.03, cr: 0 },
  { key: 'bubble',   type: T.BUBBLE,   name: '気泡',     max: 5,   rMin: 0.05,  rMax: 0.08,  sink: -0.3, cr: 1, fixedColor: '#ffffff' },
];
const MAX_PARTS = PIECES.reduce((s, p) => s + p.max, 0);

const THEMES = {
  photo: { name: '写真の色',
    glass: ['#1d3fd6', '#2f63f0', '#5a86ff', '#1a2c8f'],
    rod: ['#f2c230', '#e0a820'],
    blob: ['#58c43c', '#8ee05a'],
    crescent: ['#f5f2ea', '#e6eef5'],
    bead: ['#3a6bff', '#f2c230', '#ffffff'],
    stone: ['#5f9e7a', '#8a6ad0', '#d9cfc0'],
    star: ['#e8b64a', '#c9cfd8'],
    glitter: ['#b58ae8', '#d9dde6', '#8f6fd8', '#ffffff', '#e6c8ff'] },
  jewel: { name: '宝石',
    glass: ['#e0314f', '#f2a01c', '#2a8ee0', '#2fbf86', '#8b4fe0', '#ff6fae'],
    rod: ['#f5d547', '#e8e2d4', '#ff6fae'],
    blob: ['#2fbf86', '#35c9c9', '#8b4fe0'],
    crescent: ['#efe9dc', '#f2a01c'],
    bead: ['#c21f3a', '#1b5fbf', '#118a6a', '#efe9dc'],
    stone: ['#6fa58a', '#b86a45', '#d9cfc0'],
    star: ['#e8b64a', '#c9cfd8', '#e79a8a'],
    glitter: ['#e8c35a', '#d8dde6', '#5fd6e8', '#e45fd0'] },
  wa: { name: '和',
    glass: ['#d0473a', '#2b4c7e', '#8fb04a', '#f0a830', '#7a4b94'],
    rod: ['#c8962e', '#b22d2d'],
    blob: ['#8fb04a', '#f2b8c6'],
    crescent: ['#e8e2d4', '#f2b8c6'],
    bead: ['#b22d2d', '#23395d', '#e8e2d4'],
    stone: ['#5f9e7a', '#b5653e', '#e8e0d0'],
    star: ['#d9b25a', '#c0c4cc'],
    glitter: ['#e2bf62', '#d8dde6', '#f2b8c6'] },
  sea: { name: '海',
    glass: ['#1e88c9', '#3cc6d1', '#264e8a', '#9fd3f0'],
    rod: ['#dfe6e2', '#e8b64a'],
    blob: ['#3cc6d1', '#7fe0c5'],
    crescent: ['#f0f4f6', '#9fd3f0'],
    bead: ['#f0f4f6', '#1b5fbf', '#2bb3b1'],
    stone: ['#dfe6e2', '#8aa6a3'],
    star: ['#c9cfd8', '#e8b64a'],
    glitter: ['#bfeaf5', '#d8dde6', '#5fd6e8'] },
  dusk: { name: '夕焼け',
    glass: ['#f2552c', '#f59b2b', '#c2335b', '#6b2d6b'],
    rod: ['#f7d154', '#f59b2b'],
    blob: ['#c2335b', '#f2552c'],
    crescent: ['#f7e7c8', '#f7d154'],
    bead: ['#9e1f3f', '#f0a830', '#4a1f5c'],
    stone: ['#7a3b2e', '#d49a6a'],
    star: ['#e8b64a', '#e79a8a'],
    glitter: ['#f7d154', '#f2552c', '#e8c35a'] },
};
const themeColors = (id) => {
  const out = {};
  for (const pc of PIECES) if (!pc.fixedColor) out[pc.key] = THEMES[id][pc.key].slice();
  return out;
};
const DEFAULTS = {
  mirror: 3, points: 8, zoom: 1, theme: 'photo', viscosity: 0.5, autoRotate: 0.35, insideShape: 'solid', fade: 0.4, eyeHeight: 1.0, insideSize: 0.2, quality: 'std',
  counts: { glass: 16, rod: 10, blob: 5, crescent: 6, bead: 8, stone: 0, star: 0, glitter: 220, bubble: 1 },
  colors: themeColors('photo'),
};
// 画質ごとの設定
//   dpr/maxPx：画面の最大解像度、refl：筒をのぞくの最大反射回数、
//   iter/objects：中に入るの最大反射回数とピース数、scale：中に入るの描画解像度の範囲（重いと自動で下げる）
const QUALITY = {
  high:  { dpr: 2,   maxPx: 2.6e6, refl: 64, iter: 28, objects: 56, scale: [0.5, 1.0] },
  std:   { dpr: 1.5, maxPx: 1.6e6, refl: 40, iter: 20, objects: 40, scale: [0.3, 1.0] },
  light: { dpr: 1,   maxPx: 0.8e6, refl: 20, iter: 12, objects: 24, scale: [0.25, 0.6] },
};
const clone = (o) => JSON.parse(JSON.stringify(o));
const STORE_KEY = 'oil-kaleido-settings-v3';

function loadSettings() {
  const s = clone(DEFAULTS);
  try {
    const raw = JSON.parse(localStorage.getItem(STORE_KEY) || 'null');
    if (raw && typeof raw === 'object') {
