---
title: ADR-005 Direct Convolution
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, rtl, convolution]
---

# ADR-005: Direct Convolution veya im2col

## Durum
Kabul edildi — 2026-08-28 (fiilen daha önce alınmıştı, burada resmîleştiriliyor)

## Bağlam
Convolution'ı donanımda gerçeklemenin iki yolu var: girdiyi `im2col` ile GEMM matrisine
açmak, ya da line buffer + sliding-window generator ile doğrudan streaming convolution yapmak.
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] ve [[ADR-006 AXI Stream Paket Semantiği|ADR-006]]
zaten doğrudan convolution varsayımı üzerine yazıldı — bu ADR o varsayımı açık karara çeviriyor.

## Karar
**Doğrudan (streaming) convolution: line buffer + sliding-window generator.** Görüntü hiçbir
zaman `im2col` matrisi olarak DDR'ye açılmayacak.

Systolic array yine de **önce bağımsız GEMM olarak** doğrulanacak (Roadmap §5) — bu bir
mimari çelişki değil, doğrulama sırası: array'in matris çarpımı doğruluğu kanıtlandıktan
sonra window generator ile beslenir.

## Gerekçe
- `im2col`, girdiyi kernel boyutu katına (LeNet 3×3 için ~9×) şişirir ve bu şişmiş matrisi
  DDR'ye yazıp geri okumak gerekir. [[ADR-007 DMA Modu|ADR-007]]'nin analizinde görüldüğü gibi
  bu sistemdeki asıl darboğaz zaten veri transferi — im2col tam olarak o darboğazı büyütür.
- `Kaynaklar/IJCDS-110136-1570680228.pdf` (Huynh, aynı board) line buffer + mul-add tree ile
  doğrudan convolution kullanıyor; 32×32, 64×64 ve 128×128 girdilerin üçü de PYNQ-Z2'ye sığıyor.
- Edge FPGA'da line buffer, her piksel bir kez okunup birden çok pencerede yeniden kullanıldığı
  için Kung'un (1982) "her bellek erişimini çok kez kullan" ilkesiyle örtüşüyor.
- Fully-connected katmanlar aynı MAC altyapısını `kH=kW=1` özel durumu olarak yeniden kullanır
  ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]), yani iki ayrı veri yolu gerekmiyor.

## Alternatif
- **`im2col` + saf GEMM:** Kontrol mantığı daha basit (array'e sadece matris beslenir, window
  generator yazmak gerekmez) ama bellek trafiği ve DDR kullanımı kabul edilemez düzeyde artar.
  Elendi.

## Sonuçlar
- Window generator + line buffer, Kişi B'nin yazması gereken kritik bileşen (Roadmap §5 Aşama 3).
- Padding ve stride desteği bu modülün sorumluluğunda.
- RFF'ye (Aşama 3) 1D conv ile gidilirse line buffer `kH=1` özel durumuna indirgenir —
  yani kaydırma yazmacına dönüşür, yeniden tasarım gerekmez. Bkz. [[Kontrat Değerlendirmesi]].
