# xlive (HDMI 音声の送り口)

ここの 7 ファイルは miya4649 さんの Live_Audio_KV260_KR260_Template から、そのまま写したもの (BSD 2 条項、各ファイル先頭の表記を参照)。

- 出どころ: https://github.com/miya4649/Live_Audio_KV260_KR260_Template (commit a300828 "fixed audio volume")
- `xlive_audio`: 左右 16 ビットの標本を受け取り、PS の DP サブシステムの live audio 入力 (`dp_s_axis_audio_*`) の形
  (前置き・チャンネル状態・パリティ付きの副フレーム) にして渡す。標本を引き取る速さは HDMI 側が決める
  (音声クロック 24.576MHz = 512 × 48kHz)
- 使い方は `../i2s_stream_axi.v` の OUT_SEL (0xE0)
- 変更は 1 か所だけ: `shift_register_vector.v` を配列で書き直した (同じ動き)。元の書き方を xsim が通さないため
