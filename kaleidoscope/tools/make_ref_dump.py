# -*- coding: utf-8 -*-
"""参照実装のコピーに「取り出し口」を足した ref_dump.html を作る。

参照実装 (E:/Dropbox/claude/APP/kaleidoscope/index.html) は
IIFE で包まれていて、外からは中身に触れない。
原本は触らずにコピーを作り、IIFE の末尾に window.__k を足すだけ。

これで次が取り出せる:
  - セル画像 (奥層/手前層) の実物
  - ピースの一覧 (x,y,z,r,rot,type,seed,色)
  - 「筒をのぞく」の出力そのもの

これらは段5(ピース描画)の正解として使う。

  使い方:  python tools/make_ref_dump.py
"""
import io
import os

SRC = "E:/Dropbox/claude/APP/kaleidoscope/index.html"
DST = "E:/fpga/kria260/kaleidoscope/tools/ref_dump.html"

HOOK = """
/* ==== 取り出し口 (FPGA版の検証用に追加。原本には無い) ==== */
window.__k = {
  gl, CELL, cellTex, cellFbo, sim, settings, mirrorGeometry, viewMatrix,
  PIECES, THEMES, T, QUALITY, canvas, renderCell, renderScope,
  // セル画像を Uint8 で読み出す ('back' か 'front')
  readCell(which) {
    const n = CELL;
    gl.bindFramebuffer(gl.FRAMEBUFFER, cellFbo[which]);
    const px = new Uint8Array(n * n * 4);
    gl.readPixels(0, 0, n, n, gl.RGBA, gl.UNSIGNED_BYTE, px);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return px;
  },
  // 指定した大きさで「筒をのぞく」を描き、画素を読み出す
  //   直前に renderCell() を呼んでおけば、セル画像と出力が同じ瞬間のものになる
  renderScopeTo(w, h) {
    canvas.width = w; canvas.height = h;
    gl.viewport(0, 0, w, h);
    renderScope(w, h);
    const px = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    return px;
  },
  // ピースの一覧
  dumpParts() {
    return sim.parts.map(p => ({
      x: p.x, y: p.y, z: p.z, r: p.r, rot: p.rot, spin: p.spin,
      type: p.type, seed: p.seed, cr: p.cr, sink: p.sink, col: p.col
    }));
  }
};
"""


def main():
    src = io.open(SRC, encoding="utf-8").read()
    i = src.rindex("})();")
    out = src[:i] + HOOK + src[i:]
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    io.open(DST, "w", encoding="utf-8", newline="").write(out)
    print("wrote", DST, "(%d 行)" % out.count("\n"))


if __name__ == "__main__":
    main()
