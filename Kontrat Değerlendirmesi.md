---
title: Kontrat Değerlendirmesi
created: 2026-08-28
modified: 2026-08-28
type: note
status: active
tags: [dnn-accelerator, review, adr, kontrat]
---
bi
# Kontrat Değerlendirmesi — 2026-08-28

`Kaynaklar/` altındaki 6 paper okundu, alınan kararlarla (ADR-004/006/007/008/011)
çapraz kontrol edildi.

## Doğrulanan kararlar

| Karar | Kanıt |
| --- | --- |
| [[ADR-008 Clock Domain Stratejisi\|ADR-008]] — tek clock, 100 MHz | Huynh (IJCDS 2022) aynı board'da (PYNQ-Z2) tam olarak 100 MHz tek clock kullanıyor, tüm modüller ortak `processor system reset` altında |
| [[ADR-004 Systolic Array Boyutu\|ADR-004]] — output-stationary | Kung (1982) bu varyantı zaten tanımlıyor: "yi's stay and xi's and wi's both move" |
| Direct convolution + line buffer (ADR-005, henüz resmî değil) | Huynh line buffer + mul-add tree kullanıyor, im2col yok |
| [[ADR-006 AXI Stream Paket Semantiği\|ADR-006]] / [[ADR-007 DMA Modu\|ADR-007]] — AXI4-Stream + DMA | **En güçlü kanıt, aşağıya bak** |

### AXI-Lite tuzağı — ADR-007'nin gerekçesini doğrulayan negatif örnek

Huynh'un tasarımı IP core ile PS arasında **yalnızca AXI4-Lite** kullanıyor, DMA yok.
Sonuç (Tablo II vs III, 32×32 görüntü, 100 MHz):

- **Teorik peak:** 1034 cycle/frame → 96.759 fps
- **Gerçek sustained:** 0,033 s/frame → ~30 fps

Yaklaşık **3000 kat** fark, tamamen veri transferinden. Makale bunu açıkça kabul ediyor:
"the performance degradation is due to the data transfer between the IP core and the
external memory." Hızlandırıcı çekirdeği hızlı, sistem yavaş.

Bu, ADR-007'nin (AXI4-Stream + DMA, AXI-Lite sadece kontrol/register) neden doğru karar
olduğunun somut kanıtı — ve aynı zamanda değerlendirme metodolojisi için ders:
**peak değil sustained ölçülmeli** (Roadmap §12.4 zaten "kernel latency ile uçtan uca
latency ayrı raporlanmalı" diyor, bu madde artık kanıtlı).

## Düzeltilmesi gereken varsayım — RFF 2D/spectrogram

`Kaynaklar/J_Jian_RFonEdge_2021.pdf` (Jian et al., "RF Fingerprinting on the Edge"),
alanın SOTA çalışmalarından biri, RFF'yi **2D spectrogram olarak değil** şöyle yapıyor:

- Girdi: ham IQ, **2 × 512** slice (ekolayze veri için 2 × 198) — 1D dizi
- Ağ: **ResNet50-1D**, 49 conv katmanı, filtre genişliği 1×1 veya 1×3
- Donanım: **Xilinx ZCU104** (1728 DSP), 200 MHz, 14 W, **256-PE** tasarım
- Bunu ancak **27,2× structured pruning** sonrası sığdırabiliyorlar
- Doğruluk: WiFi-50 üzerinde %64,8 per-transmission

[[Abstract]] §8 şunu iddia ediyor: "RF sinyalinin FFT ile 2D image (spectrogram) formatına
dönüştürülmesi… sistemin özü baştan sona 2D görüntü sınıflandırmadır." Bu geçerli *bir*
yaklaşım (spectrogram tabanlı RFF literatürde var) ama vault'taki bu paper'ın yaptığı şey
değil. İki sonuç:

**İyi haber — kontratlar iki yaklaşımda da ayakta:**
- 2 × 512 INT8 slice = **1024 byte**, yani 32×32 grayscale ile *birebir aynı* frame boyutu.
  ADR-006 (TDATA=64 bit, 128 beat, TKEEP sabit all-1) değişmeden geçerli.
- 1D conv, filtre genişliği 3 = 2D conv'un `kH=1, kW=3` özel hâli. ADR-011'in adres formülü
  (`k = c_in*(kH*kW) + kh*kW + kw`) bunu zaten kapsıyor.

**Kötü haber — ölçek:**
ResNet50-1D Zynq-7020'ye hiçbir koşulda sığmaz; paper'ın kendisi 8 kat büyük bir FPGA'da,
agresif pruning sonrası ancak sığdırıyor. Aşama 3'ün *hangi* RFF ağını hedeflediği
danışmanla netleşmeden varsayılmamalı. Bu bir kontrat değil, kapsam sorusu — ama Aşama 1
kararlarını değil, Aşama 3 vaadini etkiliyor.

## Açık kalan boşluklar

1. **ADR-011'de skew belirtilmemiş.** "Tek sayaç 8 bankayı sürer" ağırlık tarafı için doğru,
   ama systolic zamanlama aktivasyonların sütun indeksine göre kaydırılmasını (skew) gerektirir.
   Bu bir hata değil, eksik — skew register'larının nerede duracağı (window generator içinde mi,
   array girişinde mi) Hafta 7 kilidinden önce yazılmalı.
2. **ADR-003 (INT8 format) hâlâ açık** ama artık somut bir veri noktası var: Huynh **Q1.7
   signed, 8-bit** kullanıp MNIST'te "no degradation in classification accuracy" raporluyor.
3. **DSP INT8 packing gerilimi.** [[Abstract]] §3.1 taşınabilirlik için generic Verilog seçiyor
   (7-series primitive'i elle instantiate edilmiyor). Bu, Xilinx WP486'nın tek DSP48E1'e iki
   INT8 MAC paketleme tekniğinden feragat etmek demek — yani 64 PE = 64 DSP, sıkı sınır.
   Savunulabilir bir takas ama ADR-004'te açıkça yazılı değil.
4. **Tarih tutarsızlığı hâlâ duruyor.** [[Abstract]] §4 tablosu Aşama 1 için "Ekim–Kasım 2026"
   diyor; gerçek kontrat: Aşama 1 en geç **Eylül sonu**, Aşama 2+3 en geç **Aralık sonu**.
5. ~~**Dosya adı karışıklığı.**~~ **Düzeltildi (2026-08-31):** dosyalar içerikle uyuşacak şekilde
   yeniden adlandırıldı — haftalık plan artık `Proje Kararları.md`, tasarım sözleşmeleri + ADR
   listesi artık `Roadmap.md`. ADR'lerdeki `[[...|Roadmap]]` linkleri de güncellendi.

## Paper değerlendirmeleri

| Paper | Değer |
| --- | --- |
| Huynh — FPGA Acceleration on PYNQ-Z2 (IJCDS 2022) | **En yakın emsal.** Aynı board, aynı problem sınıfı, 100 MHz, Q1.7, line buffer. AXI-Lite darboğazı negatif ders olarak paha biçilmez |
| Jian et al. — RF Fingerprinting on the Edge (2021) | **Aşama 3 için zorunlu okuma.** RFF'nin gerçek ölçeğini ve SOTA yaklaşımını (1D conv, IQ) gösteriyor |
| Kung — Why Systolic Architectures? (1982) | Temel ilkeler: basit/düzenli tasarım, modüler genişleyebilirlik, hesap-I/O dengesi. Output-stationary varyantı burada tanımlı |
| Sze et al. — Efficient Processing of DNNs (2017) | Ortak terminoloji, dataflow taksonomisi. Zaten planda |
| Krizhevsky et al. — AlexNet (NIPS 2012) | Tarihsel bağlam; Jian'ın RFNet'i AlexNet'ten esinli. Doğrudan tasarım girdisi yok |
| Yang et al. — Parallel PE Architecture (TST 2025) | Bit-level MAC ile 0 DSP kullanıyor (LUT'a kaydırıyor). Egzotik, yüksek riskli yön; makale aşırı iddialı ("2380952.38 times lower latency"). Bitirme projesi için **önerilmez** |
