---
title: ADR-007 DMA Modu
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, axi, dma, rtl]
---

# ADR-007: Simple DMA veya Scatter-Gather

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Görüntü/aktivasyon verisi PS↔PL arasında AXI DMA IP üzerinden taşınıyor
([[Roadmap]] §7.3). Board PYNQ-Z2, geliştirme akışı büyük olasılıkla
PYNQ Python overlay/driver framework'ü üzerinden ilerleyecek. [[ADR-006 AXI Stream Paket
Semantiği|ADR-006]] ile birlikte ele alınıyor.

## Karar
**Simple (Direct Register) Mode — Scatter-Gather DEĞİL.** Ping-pong/double buffering Aşama
1'de yok; Aşama 2/3'te gerekirse Simple DMA üzerinde yazılımsal iki-buffer toggle olarak
eklenir, SG'ye geçiş gerektirmez.

## Gerekçe
- Scatter-Gather'ın çözdüğü problem (dağınık/parçalı buffer'ları descriptor chain ile
  otomatik zincirleme) bizim senaryomuzda yok — tek, sabit boyutlu, bitişik (contiguous) bir
  buffer taşınıyor.
- **Pratik/donanımsal kısıt:** PYNQ'nun resmi Python driver framework'ü scatter-gather'ı
  desteklemiyor — "PYNQ only supports DMA from contiguous memory buffers." PYNQ akışı
  kullanılacaksa SG zaten erişilebilir bir seçenek değil; bare-metal/Linux custom driver
  yazmadan mümkün değil.
- Ping-pong buffering, Simple DMA modunda da mümkün (yazılım iki sabit buffer adresini
  sırayla LENGTH register'a yazar) — SG'ye zorlamıyor. Aşama 1 doğruluk odaklı, az sayıda
  frame simülasyonu olduğu için bu optimizasyon şimdi gereksiz.

## Alternatifler
- **Scatter-Gather DMA:** Hem problem sınıfına uymuyor (tek contiguous buffer) hem de PYNQ
  Python akışında framework seviyesinde desteklenmiyor. Elendi.

## Sonuçlar
- **Büyüme sınırı / ne zaman revize et:** RFF (Aşama 3) gerçek donanımda sürekli yüksek
  frame rate gerektirirse ve Roadmap §6.5'te zaten planlanan `STALL_IN`/`STALL_OUT`/
  `CYCLE_COUNT` register'ları per-frame CPU register-rewrite gecikmesinin darboğaz olduğunu
  ölçerse, SG'ye geçiş gündeme gelir — ama bu ancak PYNQ'dan bare-metal/Linux custom driver'a
  geçilirse mümkün. Ölçülmeden SG'ye geçmek gereksiz karmaşıklık, bu yüzden şimdi elendi.
- Kaynak: [Direct Register Mode (Simple DMA) — PG021](https://docs.amd.com/r/en-US/pg021_axi_dma/Direct-Register-Mode-Simple-DMA),
  [Scatter/Gather Mode — PG021](https://docs.amd.com/r/en-US/pg021_axi_dma/Scatter/Gather-Mode),
  [PYNQ_tutorials dma_tutorial_part1](https://github.com/cathalmccabe/PYNQ_tutorials/blob/master/dma/dma_tutorial_part1.md)

## Sonradan eklenen kanıt — 2026-08-28

`Kaynaklar/IJCDS-110136-1570680228.pdf` (Huynh, PYNQ-Z2 üzerinde CNN hızlandırma) bu kararın
neden doğru olduğunun negatif kanıtı: o tasarım PS ile IP core arasında **yalnızca AXI4-Lite**
kullanıyor, DMA yok. 32×32 görüntüde 100 MHz'de teorik peak 96.759 fps, gerçek sustained
~30 fps — yaklaşık **3000 kat** fark, tamamı veri transferinden. Makale bunu açıkça kabul
ediyor. Veri yolunu AXI4-Stream + DMA üzerine kurma kararı (kontrol/register için AXI4-Lite)
bu tuzağı baştan engelliyor. Ayrıca bkz. [[Kontrat Değerlendirmesi]].
