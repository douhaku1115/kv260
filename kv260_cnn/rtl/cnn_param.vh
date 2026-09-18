// train_mnist.py が自動生成する。手で編集しない。
//   シフト量は「積和の結果を何ビット右へずらすか」。
//   量子化のスケール合わせを 2 の冪に丸めてあるので乗算器が要らない。
localparam integer CONV1_SHIFT = 9;
localparam integer CONV2_SHIFT = 10;
localparam integer FC_SHIFT    = 0;

localparam integer C1_IN = 1,  C1_OUT = 8,  C1_SIZE = 28;
localparam integer C2_IN = 8,  C2_OUT = 16, C2_SIZE = 13;
localparam integer FC_IN = 400, FC_OUT = 10;
