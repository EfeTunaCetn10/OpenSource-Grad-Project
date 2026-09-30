---
title: ADR-011 Ağırlık Bellek Adresleme
created: 2026-08-28
modified: 2026-09-25
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, rtl, ml]
---

# ADR-011: Ağırlık Bellek Düzeni / Adresleme Şeması

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Abstract §5'te ve Proje Kararları'nda tanımlanan üç kritik kontrattan üçüncüsü: Kişi A'nın
(ML) PyTorch'tan export ettiği quantize ağırlıkların, Kişi B'nin (RTL) BRAM okuma/adresleme
şemasıyla birebir örtüşmesi. [[ADR-004 Systolic Array Boyutu|ADR-004]] (8×8, output-stationary)
ve [[Roadmap]] §5'teki doğrudan/streaming convolution (im2col değil)
kararlarının üzerine inşa ediliyor. Ağırlık depolama yeri zaten MVP kapsamında BRAM/ROM'a
önceden yükleme olarak belirlenmişti (ADR-010); bu karar onu teyit edip üstüne adresleme
şemasını ekliyor.

Output-stationary dataflow'da ağırlıklar PE içinde sabit kalmıyor — weight-stationary'nin
aksine her cycle array'e sistolik olarak akıyor (diagonal wavefront). Bu yüzden asıl soru
ağırlığın BRAM'dan hangi sırayla okunup array'e ne zaman besleneceği.

## Karar
**Ağırlıklar PyTorch'un native `[out_channels, in_channels, kH, kW]` contiguous sırasıyla
(dönüşümsüz) export edilecek; `c_out mod 8` ile 8 BRAM bankasına dağıtılacak (her banka bir
array satırına/çıktı kanalına özel); banka-içi adres `t*K + k` formülüyle hesaplanacak;
katman başına 8 adet `.coe` dosyası olarak Vivado Block Memory Generator'a yüklenecek.**

## Detay

**PyTorch tarafı (Kişi A):** Hiçbir yeniden sıralama yok. Conv ağırlık tensörü zaten
`[out_channels, in_channels, kH, kW]` C-order (kW en hızlı değişen eksen); her `c_out` dilimi
bellekte ardışık `K = in_channels × kH × kW` elemanlık blok. FC katmanlar `kH=kW=1` özel
durumu olarak aynı şemaya giriyor — Roadmap §5 Aşama 3'ün "aynı MAC altyapısını FC'de
yeniden kullan" hedefiyle örtüşüyor.

**Banking:** 8 banka, her banka bir array satırına (çıktı kanalı grubuna) özel:
`bank = c_out mod 8`. `out_channels > 8` olduğunda (örn. LeNet conv2: 16 kanal)
`tile = c_out div 8` ile ikinci geçiş yapılır — bu, zaten planlanan "partial tile desteği"
mekanizmasının ağırlık tarafındaki karşılığı, ayrı bir mekanizma icat etmiyor.

**Adres formülü:**
```
addr(bank=r, tile=t, k) = t*K + k
k = c_in*(kH*kW) + kh*kW + kw     // PyTorch native sıra, dönüşümsüz
```
`t` ve `k` tüm 8 bankaya aynı cycle'da aynı adres olarak yayılır — banka seçimi fiziksel
(hangi BRAM bloğu), adres değeri ortak. Tek bir sayaç/FSM 8 bankayı da sürer.

**Dosya formatı:** Katman başına 8 adet `.coe` — Vivado Block Memory Generator'ın native init
formatı, zaten kararlaştırılmış BRAM/ROM ön-yükleme (Roadmap §2) ile birebir uyumlu.

## Alternatifler
- **Tek büyük BRAM + adres hesaplayıcı (bankasız):** 8 array satırının aynı cycle'da 8 farklı
  ağırlığa ihtiyacı var; Zynq-7020'nin dual-port BRAM'i en fazla 2 eşzamanlı erişim verir —
  bankasız şema darboğaz yaratır. Elendi.
- **im2col-tarzı yeniden sıralanmış export:** PyTorch'un native düzenini bozar, Kişi A'ya
  gereksiz dönüşüm yükü ve hata riski ekler; doğrudan convolution zaten seçilmiş olduğu için
  kazanç yok. Elendi.

## Gerekçe
- NVDLA, ağırlıkları çıktı-kanalı gruplarına göre bankluyor (INT8 için 32'li gruplar) —
  "çıktı kanalına göre bankla" prensibi endüstride standart, 8 bankaya (array satır sayısına)
  ölçeklenmiş hâli.
- Gemmini'nin weight-stationary şemasında satırların PE'lere beslenmeden önce transpoze
  edilmesi gerekiyor; output-stationary kararımızda bu problem yok çünkü ağırlık akışı zaten
  satır-bazlı — dönüşümsüz export mümkün.
- FPGA CNN literatüründe çakışmasız erişim için ağırlıkların bağımsız BRAM bankalarına
  dağıtılması standart pratik; arbitrasyon gerektirmeyen tasarımlar tercih ediliyor.

## Sonuçlar
- Kişi A'nın export scriptinde ek dönüşüm adımı yok — doğrudan `tensor.numpy().tobytes()`
  benzeri bir çıktı, 8 dilime bölünüp `.coe`'ye yazılır.
- Kişi B'nin BRAM okuma FSM'i tek adres sayacıyla 8 bankayı paralel sürer, ayrı adresleme
  mantığı gerekmez — kontrol karmaşıklığı düşük kalıyor.
- **RFF'ye genelleme:** `K` ve `out_channels` katman parametresi olarak kalıyor, formül
  değişmiyor — sadece `.coe` dosyaları ve tile sayısı büyür. Şema LeNet-5'e gömülü değil.
- Kaynak: [Architectural Insights: Weight Stationary vs Output Stationary Systolic Arrays](https://ieeexplore.ieee.org/iel8/10892092/10892610/10892683.pdf),
  [Gemmini GitHub](https://github.com/ucb-bar/gemmini),
  [NVDLA In-memory data formats](https://nvdla.org/hw/format.html),
  [NVDLA Unit Description](https://nvdla.org/hw/v1/ias/unit_description.html),
  [An Efficient CNN Accelerator for Low-Cost Edge Systems](https://dl.acm.org/doi/10.1145/3539224)

## Ek madde — 2026-09-25: "dönüşümsüz export" FC1 için geçerli değil

Bu ADR'nin "Hiçbir yeniden sıralama yok" maddesi **conv ağırlıkları için doğru**, FC1 için
değil. Sebebi bu ADR'nin kapsamı dışında bir kararda: aktivasyonlar HWC saklanıyor
([[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]).

Pool2 çıkışı bellekte `[h][w][c]` sırasında; PyTorch `torch.flatten` ise NCHW üzerinden
`[c][h][w]` üretiyor. FC1'in `c_in` indeksi bu iki sıradan hangisine göre tanımlıysa ağırlık
sütunları ona uymak zorunda. Çözüm donanımda değil, Kişi A'nın export script'inde tek satır:

```python
w_fc1 = w_fc1.reshape(120, 16, 5, 5).permute(0, 2, 3, 1).reshape(120, 400)
```

Conv katmanlarının export'u değişmiyor; `bank = c_out mod 8` ve `addr = t*K + k` şeması
aynen geçerli. Bu madde yazılmazsa ağ çalışır ama doğruluk şans seviyesine düşer — donanımda
hiçbir bayrak yanmadığı için Hafta 8'de teşhisi pahalı bir hata sınıfıdır.

> Bu ek madde [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın HWC kararına
> bağlıdır; o karar CHW lehine değişirse permütasyon gereksiz hâle gelir.

