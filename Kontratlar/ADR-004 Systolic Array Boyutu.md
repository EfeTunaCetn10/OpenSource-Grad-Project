---
title: ADR-004 Systolic Array Boyutu
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, rtl]
---

# ADR-004: Systolic Array Boyutu

## Durum
Kabul edildi — 2026-08-28

## Bağlam
PE dizisinin boyutu (N×N), Zynq-7020 (PYNQ-Z2) çipinin 220 adet DSP48E1 slice tavanı içinde
kalmalı; aynı zamanda Aşama 3'teki RF Fingerprint (RFF) hedefinin muhtemelen LeNet-5'in 32×32
girdisinden büyük olacak spectrogram girdilerine ölçeklenebilecek bir mimari temel bırakmalı.
Dataflow zaten output-stationary olarak kilitli ([[Abstract]] §3.2); bu karar sadece dizinin
boyutunu belirliyor.

## Karar
Systolic array **8×8 (64 PE)** olarak sabitlendi — 64 DSP48E1 kullanımı, 220 DSP48E1 tavanının
%29'u.

## Alternatifler
- **4×4 (16 PE, %7 DSP):** çok güvenli DSP marjı ama tiling adım sayısı artıyor (LeNet FC1
  katmanı için ~3000 tile-step), verification/kontrol karmaşıklığı yükseliyor.
- **16×16 (256 PE):** 220 DSP48E1 tavanını aşıyor, XC7Z020'de fiziksel olarak mümkün değil.
- **10×10–12×12 (100–144 DSP, %45–65):** Stage 2'nin gerçek synthesis sonuçları (WNS, LUT
  kullanımı) rahat marj gösterirse sonradan geçilebilecek yükseltme yolu.

## Gerekçe
- Zynq-7020 sınıfında yayınlanmış iki gerçek akademik CNN accelerator, %16 ve %57 DSP
  kullanıyor — 8×8 (%29) bu aralığın ortasında, geniş marj bırakıyor.
- Literatür (Eyeriss, Zynq-7020 örnekleri) bu ölçekte darboğazın DSP değil **LUT/routing**
  olduğunu tutarlı biçimde gösteriyor — [[Roadmap]] §19'un en büyük
  riski olan timing closure'a karşı tampon sağlıyor.
- TPU'nun 256×256'sı datacenter ölçeği, Gemmini'nin 16×16 önerisi zaten DSP tavanını aşıyor —
  ikisi de bu projeye doğrudan taşınamaz.
- [[600-Arsenal/Repolar|Repolar.md]]'deki 10 repo tarandı: hiçbiri Zynq-7020 sınıfında somut
  DSP/LUT bütçesi kanıtı sunmadı, dördü (uSystolic-Sim, FusedGCN4HLS, HPDLA, ridash2005'in
  genel yaklaşımı) zaten weight-stationary kullanıyor — bizim kilitli dataflow kararımızla
  uyuşmadığı için PE-içi detayları bile doğrudan taşınmıyor. Yeni tarama karşıt kanıt
  üretmedi, 8×8 tavsiyesi doğrulandı.
- Roadmap zaten "parametrik N×N + partial tile desteği" öngörmüş (§5, Aşama 2) — kilitlenen
  N'in **ilk değeri**, mimarinin kendisi değil. RFF'ye ölçeklenebilirlik N'i büyütmekle değil,
  tiling controller'ın keyfi partial-tile'ları doğru işlemesiyle sağlanacak.

## Sonuçlar
- **Değiştirme kapısı:** Stage 2 synthesis'te 8×8 ile WNS pozitif ve LUT kullanımı düşük
  çıkarsa, 10×10–12×12'ye çıkmak DSP bütçesini aşmadan throughput artırabilir — ama bu karar
  ancak gerçek synthesis sayıları elde varken verilecek.
- Tiling controller (partial tile desteği), N sabitlendiği için artık ertelenemeyecek kritik
  bir RTL bileşeni — LeNet FC katmanları zaten N=8'i aşan tensör boyutlarına sahip, tiling
  Aşama 1'den itibaren gerçek iş yapacak.
- Kaynak: TPU (Jouppi 2017), Eyeriss (MIT ISCA 2016), Gemmini (Berkeley), Zynq-7020 CNN
  accelerator yayınları (MDPI gemi tanıma, YOLOv2), [[600-Arsenal/Repolar|Repolar.md]]'deki
  10 repo.

## Sonradan eklenen not — 2026-08-28: DSP packing feragati

[[Abstract]] §3.1'in taşınabilirlik kararı (generic Verilog, 7-series primitive'i elle
instantiate edilmiyor), Xilinx WP486'nın tek DSP48E1'e iki INT8 MAC paketleme tekniğinden
feragat etmek anlamına geliyor. Yani **64 PE = 64 DSP48E1** sıkı bir eşleme; packing
yapılsaydı aynı DSP bütçesiyle daha büyük bir array mümkün olabilirdi. Bu takas bilinçli:
taşınabilirlik ve sentez basitliği, DSP yoğunluğuna tercih edildi. %29 DSP kullanımı zaten
geniş marj bıraktığı için bu feragatin pratik maliyeti yok. Ayrıca bkz.
[[Kontrat Değerlendirmesi]].
