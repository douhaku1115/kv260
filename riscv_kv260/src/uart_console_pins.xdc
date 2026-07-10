# KOZOS UARTコンソール ピン制約 (PMOD J2, Bank45, LVCMOS33)
#   uart_tx -> B11 (J2-10) : USB-TTLアダプタの RXD(緑) へ
#   uart_rx <- D11 (J2-9)  : USB-TTLアダプタの TXD(白) から
#   GND(黒) は J2 の GND ピン。全て 3.3V。
set_property PACKAGE_PIN B11 [get_ports uart_tx]
set_property PACKAGE_PIN D11 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
