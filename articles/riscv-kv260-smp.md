---
title: "自作RISC-Vを2コアにしてSMPにする：ハードウェアロックからスレッドマイグレーションまで"
emoji: "🧩"
type: "tech"
topics: ["fpga", "kv260", "riscv", "os", "verilog"]
published: true
---

## はじめに

これまで [自作RISC-Vコアに自作OS(KOZOS流)を載せる](https://zenn.dev/douhaku1115/articles/riscv-kv260-kozos) という記事で、教科書の最小RISC-VコアをKV260上で拡張し、割込み・コンテキストスイッチ・スケジューラ・UARTコンソールまで載せて、**単一コアで自作OSの対話シェル**を動かしました。

今回はその先、**コアを2個並べて SMP（対称マルチプロセッサ）にする**ところまでやりました。ゴールは「**1つのスレッド群を2コアで分担して実行し、しかもスレッドが一方のコアで止まって別のコアで再開できる（マイグレーション）**」こと。最終的に、こういう結果が sim で出ます。

```
[完了] 総カウント=15(期待15)
  COUNTER: t0=5 t1=5 t2=5   <- 全スレッドが完走
  RANMASK: t0=1 t1=2 t2=3   <- thread2 が両コアで動いた = マイグレーション成立
```

`RANMASK` は「そのスレッドが動いたコアの bit(1<<hartid)を OR したもの」で、`3` は core0 と core1 の両方で実行されたことを意味します。自作デュアルコアRISC-Vの上で、**本物のSMPスレッドスケジューリング**が動いた瞬間です。

一気に作ると迷子になるので、**段1（共有メモリ+ロック）→ 段2（コア間割込み）→ 段3（並列ワークキュー）→ 段4（スレッド移送）** と、各段でシミュレーション→KV260実機ビルドを確認しながら積み上げました。ハマりどころも正直に書きます。

ソース一式: https://github.com/douhaku1115/kv260 の `riscv_kv260/`（`src/main_vio_smp.v` と `src/gcc/*.c`）

## 全体構成

ベースは前回の RV32I 5段パイプラインコア（`m_smpcore`）。これを2個インスタンスし、`hartid`（0/1）を入力で与えます。メモリは3種類に分けました。

- **私有IMEM/DMEM**（各コア専用）：同じプログラムを焼き込み、スタックは各コアが自分のDMEMを使う
- **共有ブロック（MMIO, `0x0003_xxxx`）**：ハードウェアロック・共有カウンタ・IPI などの制御レジスタ
- **共有RAM（デュアルポートBRAM, `0x0004_xxxx`）**：スレッドのスタックとTCBを置く（段4で追加）

```verilog
module m_top_kv260;
  m_smpcore c0 (w_clk, 2'd0, /*共有ブロック*/, /*IPI*/, /*共有RAM*/);
  m_smpcore c1 (w_clk, 2'd1, ...);
  m_shared    sh (...);   // ロック/カウンタ/IPI
  m_sharedram sr (...);   // デュアルポート共有RAM
endmodule
```

「私有DMEMがある」というのが後で効いてくる（=Cのグローバル変数の落とし穴）ので覚えておいてください。

## 段1：共有メモリとハードウェアロック

SMPで最初に要るのは**排他制御**です。ところが今回のコアは RV32IM で、**A拡張（atomic命令: LR/SC や amoswap）がありません**。そこで、ソフトのアルゴリズム（Peterson等）ではなく、**MMIOのtest-and-setロックをハードで作る**ことにしました。

共有ブロック `m_shared` に、`0x30000` をロックとして実装します。

- **読み** = test-and-set：現在値を返し、0なら取得して lock←1
- **書き** = 解放：lock←0

肝は「**両コアが同じサイクルで test-and-set したとき**」の扱いです。単純に両方が `lock==0` を見ると、両方が「取れた」と思って壊れます。そこで **core0 優先**で解決し、core1 には「core0が今取ったこと」を反映させます。

```verilog
wire acq0 = tas0 & ~r_lock;              // core0の取得
wire acq1 = tas1 & ~r_lock & ~tas0;      // core1はcore0がTASしていなければ
assign w_rd0 = {31'd0, r_lock};          // core0は現在値
assign w_rd1 = {31'd0, r_lock | acq0};   // core1はcore0の同時取得を反映
always @(posedge w_clk)
  if (rel0|rel1) r_lock <= 0;
  else if (acq0|acq1) r_lock <= 1;
```

これで**コアをストールさせずに**（両コアとも同じサイクルで確定した応答を得る）、正しい相互排他が実現できます。

テストは古典的で、**両コアが共有カウンタをロック付きで各100回インクリメント**します。

```c
for(i=0;i<100;i++){
    while(LOCK) ;      // spin-acquire (TASが0を返すまで)
    COUNT = COUNT + 1; // クリティカルセクション
    LOCK = 0;          // 解放
}
```

結果は劇的でした。

| | 共有カウンタ |
|---|---|
| ロック **あり** | **200**（正しい） |
| ロック **なし** | **100**（半分取りこぼす） |

ロック無しがきっちり100になるのが面白いところ。2コアが同一プログラムをほぼ同期して走るので、**同じ値を読んで同じ値を書き戻す**（read-modify-write が丸かぶり）ため、200回の加算が100しか効かないわけです。ロックの効果がこれ以上ないほど分かりやすく出ました。

## 段2：IPI（コア間割込み）

次はコア間で割込みを送る仕組み（IPI = Inter-Processor Interrupt）。段1のコアには割込み機構が無いので、まず**最小のCSR/割込み**（`mtvec`/`mepc`/`mstatus(MIE)`/`mret`/`csrrw/csrrs`）を、以前タイマ割込みで作った資産から移植し、**割込み源をIPIに差し替え**ました。RISC-V的には machine software interrupt（MSIP, mcause=3）に相当します。

共有ブロックに送信/ackを追加します。

- `0x30010` = IPI送信（書込値の bit で対象コアの pending を立てる）
- `0x30014` = ack（自コアの pending をクリア）

各コアの pending を割込み源として供給し、`mie`のMSIE + `mstatus`のMIEで許可すると、pendingで `mepc←PC, PC←mtvec, MIE←0`、ハンドラで ack→`mret` 復帰、という普通の割込みフローになります。

デモは、**core0がcore1へIPIを50回送信**、core1はハンドラで受信してカウント。取りこぼさないよう、受信カウンタでハンドシェイクして1件ずつ送ります。

```c
__attribute__((interrupt("machine")))
void handler(void){
    IPI_ACK = 1;             // ack
    IPICNT  = IPICNT + 1;    // 受信カウント
}
// 受信側の設定
__asm__ volatile("csrw mtvec, %0"  :: "r"(handler));
__asm__ volatile("csrw mie,   %0"  :: "r"(8));    // MSIE
__asm__ volatile("csrs mstatus,%0" :: "r"(8));    // MIE
```

結果は `受信数=50`。**2コア間で割込みが届き、相手コアがハンドラを走らせる**ことが確認できました。

:::message
このコアは即値CSR命令（`csrrwi`/`csrrsi`）を実装していないので、`csrw`/`csrs` の**レジスタ形式**だけを使っています。うっかり `csrsi mstatus, 8` と書くと壊れます。
:::

## 段3：並列ワークキュー

割込みまで揃ったところで、SMPの本命「**2コアで1つの仕事を分担する**」をやります。まずはコンテキストスイッチ不要の**実行完了型**（run-to-completion）から。

共有の `next_task`（キュー）から両コアがロックでタスクを1個ずつ取り出し、**計算はロック無しで並列実行**、結果だけロックして共有アキュムレータに足します。タスクは「`sum 1..10(k+1)` を計算」、全20個。

```c
for(;;){
    lock(); k = NEXT; if(k>=NTASK){ unlock(); break; } NEXT=k+1; unlock();
    partial = 0; for(i=1;i<=(k+1)*10;i++) partial += i;   // ← ここは2コア並列
    lock(); RESULT += partial; (h?CNT1:CNT0)++; unlock();
}
```

ロックが守るのは「キュー取得」と「結果加算」だけで、重い計算部分は2コアが並列に走ります。

| 項目 | 結果 |
|---|---|
| result（20タスクの総和） | **144550**（正しく同期・取りこぼし無し） |
| hart0 / hart1 の処理数 | **10 / 10**（両コアが均等に分担） |

`10/10` は、両コアが同じ速度でタスクを奪い合った結果きれいに割れたもの。**2コアが協調して1つのキューを処理する** SMP並列の核心が、正しい同期のもとで動きました。

## 段4：スレッド移送型スケジューラ

いよいよ最終形。**スレッドの文脈を共有RAMに置き、`swtch`（コンテキストスイッチ）で切り替え、1つのスレッド群を2コアで実行**します。ポイントは、あるコアで止めたスレッドを**別のコアで再開できる**こと。

### 共有RAM（デュアルポートBRAM）

スレッドのスタックとTCB（保存sp）を、**両コアからアクセスできる共有RAM**に置きます。Xilinxのブロック RAM は真のデュアルポートなので、2コアが独立にアクセスできます（同一番地の同時書込だけはロック/スレッド所有で避ける）。

```verilog
module m_sharedram(w_clk, a0,we0,be0,wd0,rd0, a1,we1,be1,wd1,rd1);
  reg [31:0] mem [0:1023];       // 4KB
  assign rd0 = mem[a0[11:2]];  assign rd1 = mem[a1[11:2]];
  always @(posedge w_clk) begin
    if (we0) /* byte-enable書込 */ ;
    if (we1) /* byte-enable書込 */ ;
  end
endmodule
```

各コアに2本目のメモリポートを足し、`0x0004_xxxx` へのロード/ストアをここに繋ぎます。

### swtch（コンテキストスイッチ）

xv6等でおなじみの、callee-saved レジスタをスタックに退避して sp を差し替えるやつです。

```asm
swtch:                 # a0 = 保存先アドレス, a1 = 新sp
  addi sp, sp, -52
  sw s0,0(sp); ... sw s11,44(sp); sw ra,48(sp)
  sw sp, 0(a0)         # *a0 = 現在のsp
  mv sp, a1            # sp = 新sp
  lw s0,0(sp); ... lw s11,44(sp); lw ra,48(sp)
  addi sp, sp, 52
  ret
```

**スレッドの文脈（レジスタ）は全部スレッドのスタック（=共有RAM）上に載る**ので、core0が退避した文脈を core1 の swtch がロードして復元できる = マイグレーションが成立します。スケジューラ自身の文脈は各コアの私有DMEMスタックに載せます（スケジューラは移送しない）。

### スケジューラ

各コアが同じ `sched()` を走らせ、共有レディキュー（`TCB_ST[]`）からロックで READY スレッドを取り、`swtch` で実行。スレッドが `yield()` すると戻ってきて、また READY に戻します。

```c
void sched(void){
  for(;;){
    lock(); t = find_ready(); if(t<0){ if(all_dead()){unlock();return;} unlock(); continue; }
    TCB_ST(t)=RUN; CURR(hartid)=t; unlock();
    swtch(SCHSP_A(hartid), TCB_SP(t));   // スレッド実行。yieldで戻る
    lock(); if(TCB_ST(t)==RUN) TCB_ST(t)=READY; unlock();
  }
}
```

### ハマりどころ：Cのグローバル変数は「私有」DMEMに置かれる

ここが一番の落とし穴でした。各コアは**私有DMEM**を持っているので、Cの普通のグローバル変数（`.data`/`.bss`）は**コアごとに別物**になります。スレッドが移送されると、別コアの別のグローバルを見てしまい破綻します。

なので、**スレッド間・コア間で共有する状態は、全て共有RAM/共有MMIOの固定アドレスに置き、`volatile`ポインタでアクセス**します。TCB、レディキュー、per-hart current、カウンタ…全部です。

```c
#define TCB_ST(t)  (*(volatile unsigned*)(0x00040810 + (t)*4))
#define CURR(h)    (*(volatile unsigned*)(0x00040820 + (h)*4))
#define COUNTER(t) (*(volatile unsigned*)(0x00040840 + (t)*4))
```

逆に、スレッドの**ローカル変数はスレッドのスタック（共有RAM）に載る**ので、移送されても保たれます。スレッドが自分の tid を最初に読んでローカルに持っておけば、別コアで再開しても正しく続きます。

### 結果

3スレッド × 各5回（毎回yield）で走らせると：

```
COUNTER: t0=5 t1=5 t2=5   <- 全スレッド完走
RANMASK: t0=1 t1=2 t2=3   <- t2が両コアで実行 = マイグレーション成立
```

`t2` の `RANMASK=3`（core0とcore1の両方）で、**1つのスレッドが2コアをまたいで実行された**ことが確認できました。SMPスレッドスケジューリングの完成です。

## タイミング（実機ビルド）

各段でKV260向けにビルドし、100MHz（pl_clk0）で WNS を確認しました。

| 段 | 内容 | WNS(setup) |
|---|---|---|
| 1 | 共有メモリ+ロック | +3.229ns |
| 2 | +IPI | +3.156ns |
| 3 | +並列ワークキュー | +3.148ns |
| 4 | +共有RAM+スレッド移送 | +0.450ns |

2コア＋デュアルポート共有RAMまで積むと余裕は詰まってきますが、まだプラス＝100MHz達成です。

## おわりに

単一コアの自作RISC-V+自作OSから出発して、

1. ハードウェア test-and-set ロックで共有メモリの排他を作り、
2. コア間割込み（IPI）を実装し、
3. 並列ワークキューで2コアの協調処理を実現し、
4. 共有RAM＋swtchでスレッドをコア間移送する、

というところまで、**設計→シミュレーション→KV260実機ビルド**を一段ずつ積み上げました。

SMPは「排他制御」「メモリの見え方」「コンテキストの置き場所」が全部絡むので、単一コアでは出会わないバグ（同時TASの競合、Cグローバルが私有になる問題、移送時のスタックの所在）に出会えます。**ハードとソフトの両方を自分で握っているからこそ、こういう境界のバグを最後まで追える**のが自作の面白さでした。

ソース: https://github.com/douhaku1115/kv260 の `riscv_kv260/`（`src/main_vio_smp.v`, `src/gcc/smp_sched.c` / `swtch.S` / `work_queue.c` / `ipi_test.c` として段ごとにコミットしてあります）。
