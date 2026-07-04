# 第3段 gccフロー用スタートアップ (RV32I)
#   リセットPC=0 で _start。スタック設定 → main() 呼び出し →
#   戻り値(a0)を RESULT ポート 0x0002_0000 へ store → 無限ループ停止。
    .section .text.init
    .globl _start
_start:
    la   sp, _estack          # スタック頂点 (0x0001_4000)
    call main                 # a0 = main()  (auipc+jalr で呼ぶ)
    li   t0, 0x00020000       # RESULT ポート
    sw   a0, 0(t0)            # 結果を出力(ハードが r_rslt に捕捉)
1:  j    1b                   # 停止
