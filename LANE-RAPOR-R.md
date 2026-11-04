# Lane R Raporu — Runtime Geometry

## Değişen dosyalar

- `systolic-array-8x8/rtl/weight_feeder.sv`
- `systolic-array-8x8/rtl/axi_lite_regs.sv`
- `systolic-array-8x8/rtl/accel_top.sv`
- `systolic-array-8x8/tb/tb_weight_feeder.sv`
- `systolic-array-8x8/tb/tb_axi_lite_regs.sv`
- `systolic-array-8x8/tb/tb_accel_top.sv`
- `LANE-RAPOR-R.md`

Paylaşılan `filelist.f`, `sim/run_tests.py`, model dosyaları ve başka lane'lere ait RTL/testbench dosyaları değiştirilmedi. `vivado/check_synth_accel.tcl` içerik olarak değiştirilmedi.

## Kararlar ve uygulama

- `weight_feeder` yeni `base[ADDR_W-1:0]` girişini `start` ile örneklenen `base + tile_idx*k_len` başlangıç adresine ekler. Beat başına yol yalnızca kayıtlı `next_addr` sayacını artırır. `base + (tile_idx+1)*k_len > DEPTH` komutu reddedilir ve `cfg_error` bir çevrim darbe verir.
- R lane'indeki eski `conv1_top` henüz yeni base portunu bağlayamadığı için, yalnızca simülasyonda X/Z kalan legacy giriş base=0 kabul edilir. Sentez yolu ve bağlı giriş davranışı binding sözleşmesindeki normal `base` değerini kullanır; lane G birleşince bu uyumluluk kolu etkisizdir.
- Register map v2 yapıldı: `REGMAP_VERSION=16'h0002`, `A_LAYER_CFG2=0x018` (`c_phys[8:0]`), `A_W_BASE=0x01C` (`w_base[15:0]`). RAZ/WI maskelemesi ve byte strobe birleştirmesi mevcut `A_LAYER_CFG` tarzındadır.
- `TILE_CFG[21:18]` alanı `last_rows` olarak seçildi. `0` değeri 8 satır demektir. Son olmayan tile 8 satır; son tile `last_rows==0 ? 8 : last_rows` kullanır. Böylece LeNet conv1 `tile_count=1,last_rows=6`, v3 fc2 ise tile'lar için `8 + 2` ifade edilebilir.
- `stride != 1` durumunda register bloğu START üretmez ve ERROR[7]'yi set eder.
- `accel_top` eski `C_OUT/KERN_H/KERN_W/C_IN/IN_H/IN_W/STRIDE/PAD` parametrelerini kaldırdı; envelope parametrelerini ekledi. `in_h = out_h + kh - 1 - 2*pad` ve `in_w` başarılı COMMIT sonrasında kaydedilir.
- Commit doğrulaması zamanlama için iki kayıtlı aşamadır: ilk aşama `in_h/in_w`, row bytes, weight-bank end ve temel sınır kontrollerini kaydeder; ikinci aşama ürün sınırlarını sonuçlandırır. Bu çarpımlar per-beat/per-byte yolunda değildir.
- `cfg_in_h`, `cfg_in_w`, `cfg_c_in`, `cfg_c_phys`, `cfg_kh`, `cfg_kw`, `cfg_pad` ve W-depth genişliğindeki `cfg_w_base` sinyalleri merge için hazır bırakıldı. Sözleşmeye uygun olarak R lane'i bunları eski `conv1_top` instance'ına bağlamadı; dosyada açık `INTEGRATION` yorumu vardır.

## Hata bayrağı eşlemesi

- `weight_feeder.cfg_error`: `k_len==0`, `k_len>K_MAX` veya `base + (tile_idx+1)*k_len > DEPTH` için bir çevrim darbe; komut active duruma girmez.
- `axi_lite_regs ERROR[7]` (`ERR_PARAM_INCOMPLETE`, mevcut geometry/param biti): START anında `stride!=1`, commit edilmemiş doğrudan parametreler veya geçersiz table source.
- `accel_top hw_error_set[7]` → register `ERROR[7]`: envelope dışı runtime geometri, `c_phys<c_in`, sıfır/taşan boyut, `row_bytes>ROW_BYTES_MAX`, geçersiz tile/last_rows, `cfg_k_len` sınırı, weight-bank taşması veya COMMIT sonrasında değiştirilmiş geometri ile START.
- Mevcut ERROR[0..6] eşlemesi değiştirilmedi.

## Testler

Komut: `python sim/run_tests.py -v` (`systolic-array-8x8/` altında, Vivado 2025.1 XSim).

Son özet: `16/16 passed`

R-owned PASS satırları:

- `PASS tb_weight_feeder`
- `PASS tb_weight_feeder_init`
- `PASS tb_axi_lite_regs`
- `PASS tb_accel_top: 784 bit-exact beats`

Testler nonzero weight base adreslerini, base kaynaklı bank overflow'u, v2 RAZ/WI register readback'lerini, commit darbesini, stride START reddini, COMMIT'te türetilen 32x32 input geometrisini ve active-row 6 / 8+2 durumlarını kapsar.

## Mutation sanity

Geçici mutation olarak `weight_feeder` başlangıç adresinden `base` terimi çıkarıldı. `python sim/run_tests.py -v tb_weight_feeder` sonucu `0/1 passed` oldu; test 243 adres/overflow hatası bildirdi. Doğru ifade geri yüklendi ve final regresyonda test PASS oldu.

## OOC sentez

Top: `accel_top`; device: `xc7z020clg400-1`; clock: 10 ns. Vivado script satırı:

`ACCEL_SYNTH: WNS=0.828 ns LUT=6920 FF=5360 BRAM=16 DSP=82`

10 ns zamanlama sağlandı, fakat sözleşmedeki `WNS >= +1.0 ns` hedefi 0.172 ns ile kaçırıldı; script bu yüzden `ERROR: synthesis margin below +1.0 ns` yazdı ve PASS yazmadı. En kötü yol:

- Source: `u_conv1/u_ctrl/cfg_tile_reg_reg[1]/C`
- Destination: `u_conv1/u_weights/next_addr_reg[0]/CE` (aynı fanout diğer `next_addr` bitlerinde de görülüyor)
- Data path delay: 8.919 ns (logic 3.246 ns, route 5.673 ns)
- Logic levels: 10 (`CARRY4=4, LUT2=1, LUT5=2, LUT6=3`)

İlk tek-aşamalı geometry validator sentezi WNS=-2.130 ns idi; validator iki aşamaya bölününce geometry yolu kritik olmaktan çıktı ve final WNS=+0.828 ns oldu. `PerformanceOptimized` denemesi aynı netlist/sayıları ürettiği için script değişikliği geri alındı.

## Açık sorular

- +1.0 ns sentez marjı halen sağlanmıyor. Kalan kritik yol eski `layer_ctrl` → `weight_feeder` control-enable yoludur; merge sonrasında lane G'nin runtime `conv1_top` yapısıyla tekrar ölçülmeli ve gerekirse bu kontrol yolu ayrıca pipeline/yeniden kodlama ile ele alınmalıdır.
- Merge sahibi, sözleşmede belirtildiği gibi hazır runtime sinyallerini yeni `conv1_top` portlarına ve `cfg_w_base` sinyalini `u_weights.base` portuna bağlamalıdır.
- Sözleşme ile mevcut kod arasında işi durdurmayı gerektiren başka bir çelişki bulunmadı.

## Teslim durumu

Commit oluşturma denendi, ancak linked-worktree Git index'i yazılabilir worktree dışında `C:/grad-rtl/.git/worktrees/r/index` altında bulunuyor. Sandbox bu yolu salt-okunur tuttuğu için `git add` şu hatayla durdu: `Unable to create 'C:/grad-rtl/.git/worktrees/r/index.lock': Permission denied`. Bu nedenle değişiklikler `lane/r-param` üzerinde commit edilemedi; dosyalar worktree'de hazır ve doğrulanmış durumda bırakıldı.
