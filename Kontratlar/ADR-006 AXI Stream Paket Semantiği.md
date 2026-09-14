---
title: ADR-006 AXI Stream Paket Semantiği
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, axi, rtl]
---

# ADR-006: AXI4-Stream Paket Semantiği

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Görüntü/aktivasyon verisinin PS↔PL arasında AXI4-Stream ile taşınmasında `TDATA` genişliği,
`TLAST`, `TUSER`, `TKEEP` anlamlarının netleşmesi gerekiyor ([[Proje KararlarıV2.0|Roadmap]]
§6.2 ICD). Ağırlık yolu bu kararın kapsamı dışında — ağırlıklar DMA ile değil, önceden BRAM'e
yükleniyor ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]). [[ADR-007 DMA Modu|ADR-007]] ile
birlikte ele alınıyor.

## Karar
**TDATA = 64-bit. TLAST = frame'in sonu (tüm frame, tek descriptor). TUSER = kullanılmıyor.
TKEEP = arayüzde mevcut ama fonksiyonel olarak sabit all-1.**

## Gerekçe
- Zynq-7020 üzerinde resmi PYNQ image'larındaki AXI_HP portları 64-bit genişlikte sabit —
  64-bit TDATA seçmek Data Width Converter ihtiyacını tamamen ortadan kaldırıyor.
- 32×32 INT8 LeNet-5 frame'i = 1024 byte = 64-bit'te tam 128 beat, kalan/parçalı beat
  oluşmuyor — bu yüzden TKEEP fonksiyonel olarak hiç devreye girmiyor (protokol gereği
  arayüzde bulunur, ama pratikte hep all-1).
- Xilinx'in video-IP semantiği (TLAST=end-of-line, TUSER=start-of-frame) çok satırlı raster
  video akışı için tasarlanmış; biz video IP kullanmıyoruz. Tek descriptor = tek tam frame
  olduğu için TLAST tek başına frame sınırını tamamen belirsizliksiz işaretliyor — TUSER
  (SOF) eklemek gereksiz karmaşıklık.

## Alternatifler
- **32-bit TDATA:** AXI_HP port genişliğiyle uyuşmuyor, Data Width Converter gerektirir —
  gereksiz ek IP ve timing yolu. Elendi.
- **TUSER=start-of-frame + TLAST=end-of-line (video semantiği):** Çok satırlı/raster akış
  için tasarlanmış, bizim tek-frame-tek-descriptor modelimizde karşılığı yok. Elendi.

## Sonuçlar
- RFF'ye (Aşama 3) geçişte frame boyutu büyürse (daha fazla piksel/kanal) TDATA genişliği
  aynı kalır, sadece beat sayısı artar — şema parametrik kalıyor.
- Eğer frame boyutu ileride 64-bit'e tam bölünmeyen bir tensöre dönüşürse (RFF spectrogram
  boyutuna bağlı), TKEEP'in son beat'te fonksiyonel hale gelmesi gerekecek — o noktada
  yeniden değerlendirilecek, şimdiden karmaşıklaştırılmıyor.
- Kaynak: [Model Design for AXI4-Stream Video Interface Generation — MathWorks](https://www.mathworks.com/help/hdlcoder/ug/model-design-for-axi4-stream-video-interface-generation.html),
  [FPGA-Based CNN Acceleration on Zynq-7020 (MDPI)](https://doi.org/10.3390/s26051626)
