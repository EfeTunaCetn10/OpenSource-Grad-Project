---
title: AXI Öğrenme Akışı — Sıkıştırılmış
created: 2026-09-11
modified: 2026-09-11
type: note
status: aktif
tags: [dnn-accelerator, axi, ps, kişi-b, öğrenme]
---

# AXI Stream/Lite + PS Öğrenme Akışı — Sıkıştırılmış

[[Proje Kararları]]'ndaki haftalık plan Hafta 6-8'e (9-30 Eylül) AXI/PS materyalini üç haftaya
yaymıştı. Plana bir süredir uyulamadı, şu an 8×8 array'in block design/debug aşamasındasın —
yani ihtiyaç dağınık değil, tek ve acil: **AXI Stream/Lite + PS entegrasyonu**. Aşağıdaki sıra
aynı kaynak listesini haftalara değil, "önce neyi bilmezsen şu an aldığın hatalar anlamsız
kalır" mantığına göre diziyor.

## 0. Protokol zihin modeli (önce bu — çoğu "takılı kaldı" hatası burada çözülür)

- **AXI Basics 1 — Introduction to AXI** (adaptivesupport.amd.com) — handshake kuralı
  (`TVALID`/`TREADY`, `AWVALID`/`AWREADY` vb.), üç AXI çeşidi (Lite/Stream/Full) arasındaki fark.
- Referans (baştan sona okunmaz, hata aldıkça bakılır): **ARM AMBA AXI4/AXI4-Lite/AXI4-Stream
  Protocol Specification** (Roadmap §7.1'de zaten linkli) — handshake bölümü, [[Roadmap]] §7.1'in
  zaten kilitlediği kurallarla (TVALID beklemeden üretme, TVALID=1 sonrası veri sabit tutma) birebir.

## 1. Simülasyonla doğrulama (board'da deneme-yanılma yerine)

- **AXI Basics 2 & 3 — AXI VIP ile simülasyon** — kendi IP'ni gerçek donanıma dokunmadan AXI VIP
  master/slave ile yükleyip handshake/backpressure senaryolarını burada kır. [[ADR-009 Doğrulama
  Ortamı]]'nın nihai akışı (cocotb+Icarus / XSim+SV) farklı olsa da, AXI VIP mantığını öğrenmek
  için bu hâlâ en iyi tek kaynak.

## 2. Kendi RTL'ini AXI IP olarak paketlemek (şu anki block design tıkanıklığının tam kaynağı)

- **AXI Basics 5 — Custom IP with AXI interface** — Vivado IP packager, `clk`/`rst`'i
  **Associate Clocks/Resets** ile işaretleme, AXI4-Lite register arayüzü şablonu. Önceki
  oturumda çıkardığımız `block-design-clock-reset-rehberi.md`'deki (B) yolunun resmi kaynağı bu.
- **PG085 — AXI4-Stream Infrastructure IP** (docs.amd.com/r/en-US/pg085-axi4stream-infrastructure)
  — Register Slice, Skid Buffer, Data Width/Clock Converter; [[Roadmap]] §7.2'de zaten
  planlanmış parçalar, ne zaman gerekeceğini burada gör.

## 3. PS/PL entegrasyonu (Zynq7 PS block, clock/reset, AXI interconnect)

- **AXI Basics 6 & 7 — PS bağlantısı** — Zynq7 Processing System'i block design'a ekleme,
  AXI interconnect otomatik bağlantısı, FCLK/reset dağıtımı. [[ADR-008 Clock Domain Stratejisi]]
  ile [[block-design-clock-reset-rehberi]]'nin pratikte nasıl görüneceği burada netleşir.
- **UG585 — Zynq-7000 TRM**, yalnız PS-PL arayüz (AXI_HP/GP portları) ve clock/reset bölümleri
  referans olarak — baştan sona okunacak kitap değil.
- **PG080 — Processor System Reset Product Guide** — `proc_sys_reset` IP'sinin async-assert/
  sync-deassert davranışı, önceki oturumda çıkardığımız rehberin dayandığı kaynak.

## 4. DMA (ADR-007 zaten Simple/Direct Register Mode'a kilitledi — SG bölümlerini atla)

- **PG021 — AXI DMA Product Guide**, yalnız **Direct Register Mode** bölümü.
- **PYNQ_tutorials/dma_tutorial_part1** (github.com/cathalmccabe/PYNQ_tutorials) — PYNQ Python
  driver tarafından DMA'yı görmek; board geldiğinde asıl kullanacağın akış bu.

## 5. Uçtan uca örnekler (parçaları birleştirirken referans)

- **Xilinx Embedded Design Tutorials** (xilinx.github.io/Embedded-Design-Tutorials)
- **xup_high_level_synthesis_design_flow** (github.com/Xilinx/xup_high_level_synthesis_design_flow)
  — PYNQ-Z2'ye özel, plan zaten Hafta 8 için bunu öneriyordu.

## Şu an en acil olan iki madde

Block design hatalarıyla debug ederken doğrudan işe yarayacak olanlar **madde 2 ve 3**
(AXI Basics 5, 6, 7 + PG080) — 0 ve 1'i daha önce sezgisel olarak biliyorsan atlayıp oradan
başlayabilirsin, hatanın anlamı çözülmezse 0'a geri dön.

## Not — plan gecikmesi

[[Proje Kararları]]'ndaki "Eylül sonu bitti tanımı" (PE array + AXI4-Lite/Stream + DMA + PS,
AXI VIP simülasyonunda uçtan uca çalışıyor) hâlâ geçerli hedef. Bugün 2026-09-11, plan Hafta 6
içindesin (9-15 Eylül) — asıl kayma haftalık checkpoint'lere değil, AXI/PS öğreniminin RTL
debug'ıyla aynı ana denk gelmesinde. Bu dosya iki işi birleştiriyor: öğrenirken debug et, debug
ederken öğren.
