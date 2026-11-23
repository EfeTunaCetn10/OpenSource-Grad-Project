# fpga/docs — rapor dizini

Bu klasör Kişi B (RTL/FPGA) çalışmasının kayıtlarıdır. Kod değil, karar ve kanıt izidir.
Hangi rapor hangi işin kanıtı olduğu aşağıda. Ana özet için [`../README.md`](../README.md).

## Önce bunlar

| Dosya | Ne |
| --- | --- |
| [`DURUM-RAPORU-2026-11-07.md`](DURUM-RAPORU-2026-11-07.md) | Faz 4 sonu durum: datapath, timing, kaynak, açık riskler |
| [`TEST-MATRISI.md`](TEST-MATRISI.md) | Kontrat test kimliği (`T_*`) → commit'li test eşlemesi, durum sütunuyla |
| [`delegasyon/2026-11-14 faz6 seam kontrati.md`](delegasyon/2026-11-14%20faz6%20seam%20kontrati.md) | Faz 6 kabuk işinin bağlayıcı arayüz kontratı (B-01..B-08) |

## Lane raporları

Her lane ayrı bir işi paralel yürüttü; rapor lane adını taşır. Lane adı → faz:

| Faz | Raporlar | Konu |
| --- | --- | --- |
| Faz 2 (`faz2-deneme`, 2026-10-08) | `LANE-RAPOR-actbuf`, `-axi`, `-window`, `-weight` | Ping-pong act buffer, AXI-Lite → conv1 bağlantısı, pencere üreteci, ağırlık preload |
| Faz 2 (`faz2-sim-e2e`, 2026-10-09/10) | `LANE-RAPOR-pool`, `-fc`, `-e2e`, `-integ` | 2×2 pool, FC1, LeNet-5 uçtan uca golden, entegrasyon |
| Faz 3 (parametrik) | `LANE-RAPOR-G`, `-P`, `-R` | Runtime geometri, pool geometrisi, regmap v2 |
| Faz 4 (datapath) | `LANE-RAPOR-A`, `-B`, `-C`, `-L1`..`-L4` | Act buffer, regmap v3, tek katman `accel_top`, hata tespiti, abort/watchdog |
| Faz 5 (test) | `LANE-RAPOR-P1`, `-P2`, `-P3` | Sadeleştirme, tam v3 e2e, `tb_sys_*` regresyonu |
| Faz 6 (kabuk) | `LANE-RAPOR-S6`, `-M6`, `-P6`, `-TM6`, `-B6`, `-V6` | Regmap v5 + AXIS kabuğu, netprog, PYNQ sürücüsü, mutasyon kanıtı, block design + Kademe 3, PS7 VIP DDR bulgusu |

## Alt klasörler

- [`delegasyon/`](delegasyon/README.md) — lane'lere verilen promptlar ve seam kontratları.
- [`smoke/`](smoke) — sistem smoke'u (S1–S7) üreticisi ve testbench'i.

## Not

Raporlar anlık durumu yazar; tarihli olanlar o günün kanıtıdır. Güncel gerçek için kod ve
`python sim/run_tests.py` sonucu esastır.
