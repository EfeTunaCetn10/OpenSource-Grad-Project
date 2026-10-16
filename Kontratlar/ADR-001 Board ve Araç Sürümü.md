---
title: ADR-001 Board ve Araç Sürümü
created: 2026-08-28
modified: 2026-09-27
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, vivado, pynq]
---

# ADR-001: FPGA Kartı ve Vivado Sürümü

## Durum
Kabul edildi — 2026-08-28. **Revize edildi — 2026-09-27:** Vivado 2024.1 → **2025.1**
(geçersiz kılma kuralı uygulandı, bkz. aşağıda).

## Bağlam
Kart zaten seçili (Abstract): TUL **PYNQ-Z2**, Eylül sonunda ekibe ulaşacak. Açık olan tek şey
araç sürümüydü. [[ADR-007 DMA Modu|ADR-007]] PYNQ Python akışını varsaydığı için (scatter-gather
elenmesinin gerekçesi buydu), Vivado sürümü ile PYNQ image sürümü **birlikte** kilitlenmeli —
ikisi ayrı seçilirse overlay yüklenmez.

## Karar
- **Kart:** TUL PYNQ-Z2, part **`xc7z020clg400-1`**
- **Vivado:** **2025.1**
- **PYNQ SD image:** ⚠️ **açık** — kart gelince eşleşme doğrulanacak, bkz. "Açık uç" bölümü
- Board file'ları Vivado Board Store üzerinden kurulacak (2020.x sonrası elle kopyalama gerekmiyor)
- Her iki geliştirici de **aynı sürümü** kullanacak; sürüm `README`'ye ve her sonuç kaydına yazılacak

## Gerekçe
- **Sürüm 2025.1, çalışan kurulumun sürümüdür.** Geliştirme makinesinde Vivado 2025.1 kurulu ve
  tüm doğrulama zinciri (`sim/run_tests.py`, XSim) ile sentez kapısı (`vivado/check_synth.tcl`)
  bu sürümde koşuyor. 2026-09-26 sentezi ve 2026-09-27 regresyonu 2025.1 ile alındı:
  64 DSP48, WNS +3.074 ns @100 MHz, 6/6 test PASS.
- 2024.1'e dönmek, kanıtlanmış sonuçları elde bir kurulumu bırakıp yeniden üretmek demekti.
  Bu tam olarak aşağıdaki geçersiz kılma kuralının öngördüğü durum: **çalışan kuruluma sahip
  olmak, sürüm eşleşmesinden önce gelir.**
- XC7Z020 ücretsiz **WebPACK** lisansıyla destekleniyor — ek lisans maliyeti yok.
- Aşama 1 tamamen PL tarafı ve simülasyon/sentez ile kapanıyor; PYNQ image sürümü Aşama 1'in
  hiçbir kabul kriterine girmiyor. Yani bu revizyon Aşama 1'i bloklamıyor, riski Aşama 2'ye
  taşıyor ve orada açıkça ele alınıyor.

## ⚠️ Açık uç: PYNQ image eşleşmesi
Orijinal karar PYNQ v3.1'i seçmişti çünkü PYNQ image sürümü ile Vivado sürümü birebir bağlıdır:
v2.7→2020.2, v3.0→2022.1, v3.1→2024.1. **Vivado 2025.1 için eşleşen bir PYNQ image sürümü bu
ADR yazılırken doğrulanmadı.** Bu bilerek açık bırakıldı; uydurulmuş bir eşleşme yazmak,
Aşama 2'de overlay yükleme hatası olarak geri döner.

Karar kuralı — kart eldeyken, Aşama 2 başlamadan önce sırayla:
1. PYNQ resmi board/changelog sayfasından PYNQ-Z2 için mevcut en yeni image ve onun
   beklediği Vivado sürümü okunacak.
2. 2025.1'i karşılayan bir image varsa o seçilecek ve bu ADR'ye yazılacak.
3. Yoksa iki yol karşılaştırılacak: (a) PL bitstream/`.hwh` metadata'sını mevcut image'ın
   beklediği sürümde yeniden üretmek, (b) image'ı olduğu gibi kullanıp overlay yüklemeyi
   önce küçük bir pass-through tasarımıyla denemek.
4. Hangisi seçilirse seçilsin, sonuç bu ADR'ye ve Roadmap'e yazılacak.

Bu doğrulama Aşama 2'nin **ilk** işidir, sonraya bırakılmaz: ADR-007'nin DMA seçimi PYNQ
Python akışına dayanıyor, yani overlay yüklenemezse etkilenen tek şey bir sürüm numarası değil.

## Alternatif
- **Vivado 2024.1 + PYNQ v3.1 (orijinal karar):** Belgelenmiş, kesin bir eşleşme. Bedeli,
  çalışan 2025.1 kurulumunu bırakıp mevcut sentez ve simülasyon sonuçlarını yeniden üretmek.
- **PYNQ v3.0 + Vivado 2022.1:** İki yıl daha fazla birikmiş forum/Stack Overflow cevabı var,
  takılınca çözüm bulmak biraz daha kolay. Gerçek bir avantaj, ama destek ufku daha kısa.

## ⚠️ Geçersiz kılma kuralı
**Üniversite laboratuvarındaki makinelerde farklı bir Vivado sürümü kuruluysa, o sürüme uy.**
Çalışan bir kuruluma erişimi kaybetmenin maliyeti, herhangi bir sürüm farkının maliyetinden
yüksektir. Bu durumda PYNQ image'ı da eşleşen sürüme çekilecek ve bu ADR güncellenecek.
**2026-09-27'de tam olarak bu oldu:** kurulum 2025.1 çıktı, karar ona uyduruldu, image tarafı
"Açık uç" bölümüne taşındı.

## Sonuçlar
- Roadmap §19'un "Araç sürümü farkı → tekrar üretilemeyen build" riski bu maddeyle kapanıyor —
  ama artık tek bir sürüm numarasıyla değil, 2025.1 + doğrulanacak image çiftiyle.
- Vivado projesi Git'e ham dosya olarak değil, **Tcl script** olarak saklanacak (Roadmap §15) —
  sürüm sabitlemesi ancak bununla anlamlı olur. Karşılığı `vivado/create_project.tcl`
  (2026-09-27'de eklendi); `vivado/.project/` gitignore'da.
- Aşama 1'in tüm kayıtlı sonuçları 2025.1 ile alınmıştır. Sürüm bir daha değişirse sentez
  kapısı ve XSim regresyonu yeniden koşturulup sonuçlar güncellenecek.

## Kaynaklar
- [PYNQ supported boards ve pre-built image'lar](http://www.pynq.io/boards.html)
- [PYNQ Change Log — sürüm/toolchain eşleşmesi](https://pynq.readthedocs.io/en/latest/changelog.html)
- [Vivado Board Files — UG892](https://docs.amd.com/r/2022.2-English/ug892-vivado-design-flows-overview/Board-Files)
