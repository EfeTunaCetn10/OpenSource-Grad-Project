---
title: ADR-008 Clock Domain Stratejisi
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, cdc, rtl]
---

# ADR-008: Clock Domain Stratejisi

## Durum
Kabul edildi — 2026-08-28

## Bağlam
PL içindeki custom RTL'in (systolic array + PE'ler + AXI4-Lite/Stream wrapper + line
buffer/window generator) kaç clock domain'de çalışacağı kararı. PS-PL sınırı kapsam dışı —
Xilinx'in önceden doğrulanmış AXI interconnect/clock-converter IP'leri o geçişi zaten
kapsıyor. [[ADR-004 Systolic Array Boyutu|ADR-004]] (8×8 array, 64 DSP48E1) üzerine inşa
ediliyor. [[Proje KararlarıV2.0|Roadmap]] §6.4/§8'deki CDC karar tablosu ve reset yaklaşımı
bu kararla birlikte geçerliliğini koruyor, yeniden yazılmıyor.

## Karar
**Tek clock domain — tüm PL custom RTL aynı fabric clock'ta (FCLK0), hedef 100 MHz.** PS-PL
sınırı hariç iç mantıkta hiç CDC senkronizatörü gerekmiyor; reset tek domain içinde
async-assert/sync-deassert ile yeterli (Roadmap §8.3).

## Gerekçe
- Zynq-7000 -1 speed grade'de DSP48E1 slice'ın tam pipeline'lı fMAX'i ~241 MHz (DS187) — 8×8
  array'deki 64 DSP'nin kendi hızı 100 MHz hedefinin 2,4 kat üzerinde marja sahip. Compute
  core'u ayrı, daha yüksek bir clock'ta çalıştırmanın performans gerekçesi yok; darboğaz
  DSP'nin Fmax'i değil.
- Zynq-7020 sınıfında yayınlanmış streaming/systolic CNN accelerator'ları tek clock domain,
  66–100 MHz aralığında timing kapatıyor — biri 100 MHz'i PS/PL arayüzünü kararlı tutmak için
  bilinçli muhafazakâr bir tercih olarak seçtiğini açıkça belirtiyor. Projenin kendi örnek
  hedefi (Roadmap §6.1, REQ-PERF-001) bununla doğrudan örtüşüyor.
- CDC'yi ciddi doğrulamak (SpyGlass/Conformal CDC seviyesinde, ya da en azından disiplinli
  senkronizatör kütüphanesi + `report_cdc` + ayrı statik/dinamik doğrulama) 2 kişilik,
  Eylül-Aralık sıkışık takvimli bir ekip için gerçek zaman bütçesiyle karşılanamıyor —
  Roadmap §19'un zaten en yüksek etkili risk olarak işaretlediği CDC hatasını, çoklu clock
  seçmek gereksiz yere büyütür.

## Alternatifler
- **İki domain — compute core yüksek clock, AXI arayüz düşük/sabit clock:** DSP48E1'in
  241MHz Fmax'i zaten 100MHz hedefini rahat karşıladığı için performans kazancı marjinal;
  buna karşılık CDC doğrulama yükü (senkronizatör tasarımı, lint, ekstra testbench
  senaryoları) kazanç/risk oranını negatife çeviriyor. Elendi.

## Sonuçlar
- **Revize tetikleyicisi:** Stage 2 synthesis sonrası WNS negatif çıkar ve pipeline eklemek
  veya frekansı düşürmek yetmezse (100MHz tek domain'de LUT/routing gerçekten tıkanırsa),
  compute/interface ayrımı o noktada yeniden değerlendirilir — önden varsayılmıyor, ölçülmeden
  CDC riskine girilmiyor.
- Reset ve CDC'nin genel prensipleri (Roadmap §6.4/§8: async assert/sync deassert, yasak
  pratikler, `report_cdc` geçiş kriterleri) tek domain kararıyla birlikte hâlâ geçerli — PS-PL
  sınırındaki AXI interconnect'in kendi iç CDC'si için uygulanıyor.
- Kaynak: [DS187 Zynq-7000 Data Sheet — DSP48E1 switching characteristics](https://www.mouser.com/datasheet/2/690/ds187_XC7Z010_XC7Z020_Data_Sheet-2487127.pdf),
  [FPGA-Based CNN Acceleration on Zynq-7020 — Ship Recognition (MDPI)](https://doi.org/10.3390/s26051626),
  [High-Speed CNN Accelerator SoC — Flexible Diagonal Cyclic Array (MDPI)](https://doi.org/10.3390/electronics13081564),
  [First-Time FPGA Success Requires Exhaustive Examination of CDC — Electronic Design](https://www.electronicdesign.com/technologies/analog/article/21118802/mentor-a-siemens-business-first-time-fpga-success-requires-exhaustive-examination-of-clock-domain-crossings)
