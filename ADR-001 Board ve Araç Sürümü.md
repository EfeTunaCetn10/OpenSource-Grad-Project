---
title: ADR-001 Board ve Araç Sürümü
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, vivado, pynq]
---

# ADR-001: FPGA Kartı ve Vivado Sürümü

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Kart zaten seçili (Abstract): TUL **PYNQ-Z2**, Eylül sonunda ekibe ulaşacak. Açık olan tek şey
araç sürümüydü. [[ADR-007 DMA Modu|ADR-007]] PYNQ Python akışını varsaydığı için (scatter-gather
elenmesinin gerekçesi buydu), Vivado sürümü ile PYNQ image sürümü **birlikte** kilitlenmeli —
ikisi ayrı seçilirse overlay yüklenmez.

## Karar
- **Kart:** TUL PYNQ-Z2, part **`xc7z020clg400-1`**
- **Vivado:** **2024.1**
- **PYNQ SD image:** **v3.1**
- Board file'ları Vivado Board Store üzerinden kurulacak (2020.x sonrası elle kopyalama gerekmiyor)
- Her iki geliştirici de **aynı sürümü** kullanacak; sürüm `README`'ye ve her sonuç kaydına yazılacak

## Gerekçe
- PYNQ image sürümü ile Vivado sürümü birebir bağlı: v2.7→2020.2, v3.0→2022.1, **v3.1→2024.1**.
  Eşleşmeyen çift, overlay yükleme hatası olarak Aşama 2'de ortaya çıkar.
- PYNQ-Z2 için hem v3.0 hem v3.1 hazır image mevcut, yani ikisi de mümkündü.
- v3.1/2024.1 seçildi çünkü Aralık 2026'ya kadar sürecek bir proje için daha uzun destek
  ufku sunuyor ve kart Eylül sonunda geleceği için güncel image ile başlamak ek downgrade
  işi çıkarmıyor.
- XC7Z020 ücretsiz **WebPACK** lisansıyla destekleniyor — ek lisans maliyeti yok.

## Alternatif
- **PYNQ v3.0 + Vivado 2022.1:** İki yıl daha fazla birikmiş forum/Stack Overflow cevabı var,
  takılınca çözüm bulmak biraz daha kolay. Gerçek bir avantaj, ama destek ufku daha kısa.

## ⚠️ Geçersiz kılma kuralı
**Üniversite laboratuvarındaki makinelerde farklı bir Vivado sürümü kuruluysa, o sürüme uy.**
Çalışan bir kuruluma erişimi kaybetmenin maliyeti, herhangi bir sürüm farkının maliyetinden
yüksektir. Bu durumda PYNQ image'ı da eşleşen sürüme çekilecek ve bu ADR güncellenecek.

## Sonuçlar
- Roadmap §19'un "Araç sürümü farkı → tekrar üretilemeyen build" riski bu maddeyle kapanıyor.
- Vivado projesi Git'e ham dosya olarak değil, **Tcl script** olarak saklanacak (Roadmap §15) —
  sürüm sabitlemesi ancak bununla anlamlı olur.

## Kaynaklar
- [PYNQ supported boards ve pre-built image'lar](http://www.pynq.io/boards.html)
- [PYNQ Change Log — sürüm/toolchain eşleşmesi](https://pynq.readthedocs.io/en/latest/changelog.html)
- [Vivado Board Files — UG892](https://docs.amd.com/r/2022.2-English/ug892-vivado-design-flows-overview/Board-Files)
