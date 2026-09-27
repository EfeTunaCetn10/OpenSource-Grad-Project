---
title: ADR-009 Doğrulama Ortamı
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, verification, cocotb, xsim]
---

# ADR-009: cocotb veya UVM Doğrulama Ortamı

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Roadmap §9 cocotb'yi ana regression ortamı, AXI VIP'i protokol doğrulaması olarak öneriyor;
Hafta 8 planı ise "cocotb ile golden model ↔ RTL karşılaştırması" ve "AXI VIP testbench"i aynı
uçtan uca kurulumda varsayıyor. **Bu ikisi doğrudan birleştirilemez** — aşağıdaki çakışma bu
ADR'nin asıl konusu.

## ⚠️ Çakışma: cocotb ile AXI VIP aynı simülatörde buluşmuyor

- **cocotb, Vivado XSim'i resmî olarak desteklemiyor.** Yalnızca üçüncü taraf `cocotb-vivado`
  projesi var; o da ciddi kısıtlı (sadece top-level portlara erişim, sadece `Timer` trigger'ı).
- **Icarus Verilog, Vivado IP'lerini simüle edemiyor.** AXI VIP, AXI DMA, Block Memory
  Generator ve Zynq PS bloğu şifreli Xilinx IP'leri — Icarus/Verilator bunları çalıştıramaz.

Yani "cocotb + AXI VIP + DMA + PS, hepsi tek testbench'te" planı Hafta 8'de duvara çarpardı.

## Karar — iki katmanlı doğrulama

**Katman 1 — saf RTL birimleri: cocotb + Icarus Verilog**
Kişi B'nin kendi yazdığı, Xilinx IP içermeyen her şey: PE, requantizer, systolic array, line
buffer, window generator, AXI4-Stream wrapper. Golden model karşılaştırmasının **tamamı burada**
yaşıyor — [[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün `T_NUM_REQ_001` testi dahil.
Verilator lint amaçlı ikinci göz olarak kullanılıyor (Roadmap §9 zaten böyle listelemiş).

**Katman 2 — Xilinx IP'li sistem entegrasyonu: Vivado XSim + SystemVerilog testbench**
AXI VIP, AXI DMA, BRAM generator, Zynq PS BFM. Burada cocotb **yok**, düz SV testbench var.

**Köprü — dosya tabanlı el sıkışma:**
Golden model karşılaştırmasının simülatörün *içinde canlı* olması gerekmiyor. Kişi A test
vektörlerini dosyaya üretir → RTL simülasyonu (hangi katman olursa olsun) `$readmemh` ile okur,
çıktısını dosyaya yazar → Python offline karşılaştırır. Bu, iki katmanı birbirinden ayırıyor ve
cocotb/XSim sorununu tamamen ortadan kaldırıyor.

**UVM:** Kavramları öğrenilecek (driver, monitor, scoreboard, sequence, coverage — bunlar
cocotb'de de aynı yapıdır), ama tam UVM ortamı **kurulmayacak**. Roadmap §9.2'nin önerisi aynen
korunuyor: sıfırdan başlayan iki kişilik ekipte UVM projenin ana hedefini gölgeler.

## Alternatifler
- **Her şeyi XSim + SV testbench'te yapmak:** cocotb sorunu yok ama golden model Python'da
  olduğu için köprü yine dosya tabanlı olurdu, ve birim testleri yazmak/koşturmak çok daha yavaş.
  Elendi.
- **`cocotb-vivado` ile tek ortam:** Sadece top-level portlara erişim ve tek trigger tipi;
  bir bitirme projesinin ana doğrulama altyapısını bu kısıtların üzerine kurmak riskli. Elendi.
- **Tam UVM:** Öğrenme maliyeti Eylül-Aralık takvimine sığmıyor. Elendi.

## Sonuçlar
- Roadmap §13 Hafta 8'in "cocotb ile uçtan uca otomatik karşılaştırma" maddesi **düzeltilmeli**:
  uçtan uca sistem simülasyonu XSim'de SV testbench ile, karşılaştırma dosya üzerinden offline.
- Kişi B iki testbench iskeleti kuracak, biri değil — bu Hafta 6-7 iş yüküne eklenmeli.
- CI'da yalnızca Katman 1 koşabilir (Icarus ücretsiz ve headless). Katman 2 elle/lokal koşulur.

## Kaynaklar
- [cocotb Simulator Support](https://docs.cocotb.org/en/stable/simulator_support.html)
- [cocotb Discussion #3661 — Vivado IP'lerinin simülatör desteği](https://github.com/cocotb/cocotb/discussions/3661)
- [cocotb-vivado (üçüncü taraf, kısıtlı)](https://github.com/themperek/cocotb-vivado)
- [AMD AXI Verification IP — PG267](https://docs.amd.com/r/en-US/pg267-axi-vip)

## ⚠️ Ek madde — 2026-09-26: simülatör seçimi düşürüldü

> [!warning] Bu ADR'nin **simülatör** kararı geçersiz.
> Yerine [[ADR-017 Simülasyon ve Emülasyon Ortamı|ADR-017]] geçti. İki katmanlı ayrım ve
> dosya köprüsü **aynen geçerli**; yalnız her iki katman da XSim'de koşuyor.

Bu ADR'nin "Katman 1 = cocotb + Icarus Verilog" kararı **Vivado'nun bu makinede kurulu
olmadığı varsayımına** dayanıyordu. Varsayım yanlıştı: 2026-09-26'da Vivado 2025.1'in kurulu
ve çalışır olduğu doğrulandı (`xvlog`/`xelab`/`xsim`, `xc7z020` destekli;
`processing_system7_vip`, `axi_vip`, `axi4stream_vip`, `axi_dma` diskte mevcut).

**Bu ADR'nin kaydettiği çakışmanın sebebi böylece ortadan kalkıyor.** "cocotb XSim'i
desteklemiyor, Icarus şifreli Xilinx IP'sini simüle edemiyor" ikilemi iki simülatör
gerektirdiği için vardı; XSim üçünü de (saf RTL, SVA, şifreli IP) koşturduğundan tek
simülatör yetiyor.

Düşen maddeler:
- "Katman 1 — cocotb + Icarus Verilog" → **XSim + SystemVerilog testbench**.
- "CI'da yalnızca Katman 1 koşabilir (Icarus ücretsiz ve headless)" → XSim headless koşar ama
  Vivado kurulumu ister, yani ücretsiz public CI'da koşmaz. **Burada CI, lokal regression
  demek:** `systolic-array-8x8/sim/run_tests.py`, her commit öncesi.
- `tb/cocotb/` (Makefile + `test_requantizer.py`) ölü yol. Vektör kapsamı SV testbench'e
  taşındıktan sonra silinecek.

Korunan ve asıl değerli madde **dosya tabanlı golden model köprüsü**: golden model
simülatörün içinde canlı olmak zorunda değil, Python vektör üretir, RTL `$readmemh` ile okur,
karşılaştırma dosya üzerinden yapılır. Tek simülatörde bu daha da doğal hâle geldi.

**Ölçülen bedel:** `T_NUM_REQ_001` 2026-09-11'de yazıldı ve **15 gün hiç koşmadı**, çünkü
cocotb ve Icarus kurulu değildi — oysa aynı testi koşturacak simülatör baştan beri
makinedeydi. Araç kararlarında "kurulu mu?" sorusu "en iyisi hangisi?" sorusundan önce
gelmeliydi.
