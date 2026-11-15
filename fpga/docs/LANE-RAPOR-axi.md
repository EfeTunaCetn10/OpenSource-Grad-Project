# Lane L3 (axi) raporu — 2026-10-08

Branch: `lane/axi`. RTL kökü: `systolic-array-8x8/`.

## Yazılanlar

| Dosya | Son satır sayısı | İş |
| --- | ---: | --- |
| `rtl/axi_lite_regs.sv` | 466 | ADR-015 alan çıkışları, bit 31 RAZ/WI, commit anında kayıtlı `cfg_k_len` |
| `rtl/accel_top.sv` | 184 | AXI–conv1 bağlantısı, geometri başlangıç koruması, durum ve sayaçlar |
| `tb/tb_axi_lite_regs.sv` | 384 | Alan, maske ve `k_len` kontrolleri |
| `tb/tb_accel_top.sv` | 218 | `T_ACCEL_CTRL_001`, AXI üzerinden parametre ve frame, ağırlık portu, 784 bit-exact çıktı |
| `filelist.f` | 18 | AXI register dosyası ve wrapper eklendi |
| `vivado/check_synth_accel.tcl` | 35 | `accel_top` OOC sentez kapısı |
| `LANE-RAPOR.md` | 49 | Lane teslim ve açık maddeler |

`conv1_top.sv` değiştirilmedi. `LANE-RAPOR.md` worktree köküne eklendi.

## Doğrulama

- `python sim/run_tests.py tb_axi_lite_regs tb_accel_top`: 2/2 PASS.
- Son değişikliklerden sonra `python sim/run_tests.py`: 11/11 PASS, 24 SV dosyası derlendi.
- `tb_accel_top`: 784/784 çıkış beat'i `c1_y.mem` ile bit düzeyinde eşleşti. 24 parametre word'ünün maskesi, commit, ağırlık yazma portu, BUSY/DONE/W1C, dört performans sayacı ve geometri reddi doğrulandı.
- `git diff --check`: hata yok.

## Sentez

Vivado 2025.1, `vivado/check_synth_accel.tcl`, `accel_top`, OOC, `xc7z020clg400-1`, 10 ns clock: **WNS +1,157 ns; LUT 5369; FF 4341; BRAM 12; DSP 60**. +1,0 ns sentez payı kapısı geçti. En kötü yol `u_conv1/u_ctrl/cfg_tile_reg` → `u_conv1/u_weights/beats_accepted_reg`; AXI yolu değil. Bunlar sentez sayılarıdır; place/route çalıştırılmadı.

## Mutasyonlar

Her mutant tek başına enjekte edildi, belirtilen XSim testi FAIL verdi ve kaynak baytları geri yüklendi:

| Mutant | Yakalayan kontrol | Sonuç |
| --- | --- | --- |
| `cfg_k_len` off-by-one | Commit sonrası kayıtlı `k_len` | Yakalandı |
| START geometri polaritesi ters | Çıktı timeout, BUSY/DONE yok | Yakalandı |
| `out_W` yanlış bit alanı | Decode karşılaştırması | Yakalandı |
| `STALL_OUT` için `!m_ready` yerine `m_ready` | Tam cycle sayısı | Yakalandı |
| `STALL_OUT` reset değeri 1 | Tam cycle sayısı | Yakalandı |

## Açık kalanlar ve belirsizlikler

- `TILE_CFG.tile_count` output-channel tile sayısıdır; son tile'ın aktif satır sayısını tek başına vermez. Bu wrapper sabit conv1 için `C_OUT=6`, `tile_count=1`, `tile_idx=0` koşulunu kullanır. Genel katmanlarda aktif satır sayısı Faz 2 tasarım kararı gerektirir.
- ADR-015 geometri uyuşmazlığı için ayrı ERROR biti tanımlamıyor. Wrapper START'ı engelleyip `ERR_PARAM_INCOMPLETE[7]` set ediyor. Yazılımın geometri hatasını eksik parametreden ayırması için register-map kararı gerekir.
- `soft_reset` yalnız `accel_top` çıkışına verilmiştir; window restart bağlantısı Faz 2'de yapılacak. Dolayısıyla bu aşamada aynı reset aralığında ikinci frame çalıştırılamaz.
- ADR-015'in ERROR bitleri `layer_ctrl` hata alt türleriyle birebir örtüşmüyor. Wrapper'daki eşleme yorumlarda açık; özellikle `ERR_TLAST_LATE` ve `ERR_TIMEOUT` alt türleri için yazılım semantiği Faz 2'de netleştirilmeli. `drain_stall` normal backpressure olduğu için ERROR'a bağlanmadı.
- OOC sentezde DSP sayısı 60; önceki `conv1_top` kontrol scriptindeki 80 beklentisinden düşük. Bu farkın nedeni ayrıca incelenmeli. Route sonrası WNS bilinmiyor; +1,157 ns sentez payı, eşik üzerinde yalnız 0,157 ns kalıyor.
- Sahiplik tablosu dışında, kullanıcının açık teslim talebi gereği ortak `filelist.f` ve yeni `vivado/check_synth_accel.tcl` değiştirildi. Başka lane dosyası değiştirilmedi.
