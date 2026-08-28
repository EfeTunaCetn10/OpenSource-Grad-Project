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
