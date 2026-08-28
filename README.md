# ARM Tabanlı FPGA-SoC Üzerinde Gerçeklenen Özel DNN Accelerator Mimarisi

Bitirme projesi — Zynq-7000 (PYNQ-Z2) üzerinde, systolic-array tabanlı özgün bir INT8 DNN
donanım hızlandırıcısının tasarımı, doğrulanması ve RF Fingerprint sınıflandırmaya
uyarlanması. Proje özeti için bkz. [`Abstract.md`](./Abstract.md).

> Bu repo şu an **private**. Proje LinkedIn'de paylaşılırken public'e çevrilecek.

## İçerik

- **`Abstract.md`** — proje özeti, motivasyon, aşamalı yol haritası
- **`Roadmap.md`** — 16 haftalık teknik uygulama planı
- **`Proje KararlarıV2.0.md`** — tasarım sözleşmeleri çerçevesi, ADR listesi
- **`ADR-*.md`** — mimari karar kayıtları (Architecture Decision Records), her biri gerekçe
  ve elenen alternatifleriyle:
  - `ADR-001` Board ve araç sürümü
  - `ADR-002` CNN topolojisi ve dataset
  - `ADR-003` INT8 fixed-point format
  - `ADR-004` Systolic array boyutu
  - `ADR-005` Direct convolution
  - `ADR-006` AXI Stream paket semantiği
  - `ADR-007` DMA modu
  - `ADR-008` Clock domain stratejisi
  - `ADR-009` Doğrulama ortamı
  - `ADR-011` Ağırlık bellek adresleme
- **`Kontrat Değerlendirmesi.md`** — kararların literatür ve emsal projelerle çapraz doğrulaması
- **`Kaynaklar/`** — referans makaleler (bu repoda değil, ayrıca indirilmeli — bkz. `.gitignore`)

## Not

Bu dosyalar bir [Obsidian](https://obsidian.md) vault'unun parçası olarak yazıldı; aralarındaki
`[[wikilink]]` biçimindeki bağlantılar Obsidian dışında (örn. doğrudan GitHub'da) tıklanabilir
köprü olarak görünmez, düz metin olarak kalır.
