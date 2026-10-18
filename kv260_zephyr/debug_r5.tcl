# R5 #0 を止めて、アボートの情報 (DFSR/DFAR) と PC・LR を読む。止まった PC は addr2line で引く
connect
targets -set -nocase -filter {name =~ "*R5*#0"}
catch {stop}
puts "ABT: [rrd abt]"
puts "SVC: [rrd svc]"
puts "C5:  [rrd cp15 5]"
puts "C6:  [rrd cp15 6]"
puts "PC:  [rrd pc]  LR: [rrd lr]"
con
disconnect
