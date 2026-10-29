/*
  Copyright (c) 2023 miya
  All rights reserved.

  Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

  2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/* shift_register_vector ver.2 */

// DEPTH >= 1
// Latency = DEPTH

module shift_register_vector
  #(
    parameter WIDTH = 8,
    parameter DEPTH = 3
    )
  (
   input wire              clk,
   input wire [WIDTH-1:0]  data_in,
   output wire [WIDTH-1:0] data_out
   );

  // kv260_nes: 元は generate で delay_gen[i+1] を参照していたが、xsim が範囲外 (i = DEPTH-1) の
  // 参照で elaborate を止めるので、同じ動き (data_in → [DEPTH-1] → … → [0] → data_out) を配列で書く
  reg [WIDTH-1:0] temp_reg [0:DEPTH-1];
  integer i;
  always @(posedge clk)
    begin
      temp_reg[DEPTH-1] <= data_in;
      for (i = 0; i < DEPTH-1; i = i + 1)
        temp_reg[i] <= temp_reg[i+1];
    end
  assign data_out = temp_reg[0];

endmodule
