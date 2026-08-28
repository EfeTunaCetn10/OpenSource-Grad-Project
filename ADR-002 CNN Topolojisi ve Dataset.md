---
title: ADR-002 CNN Topolojisi ve Dataset
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, ml, dataset]
---

# ADR-002: CNN Topolojisi ve Dataset

## Durum
Kabul edildi — 2026-08-28 (girdi formatı aynı gün RGB olarak kapatıldı)

## Karar (kesin kısım)
- **Topoloji:** LeNet-5 (2 conv + pooling + 3 FC), sabit boyutlu, tek precision
- **Precision:** INT8 ([[ADR-003 INT8 Fixed-Point Formatı|ADR-003]])
- **Batch:** 1
- **Sınıf sayısı:** 10
- **Girdi:** **32×32 RGB** (`c_in = 3`), INT8 kanal başına
- **Eğitim sırası:** Önce MNIST (Hafta 3, referans/doğrulama), sonra hedef veri seti (Hafta 4+)
- **Hedef veri seti:** Böcek türü sınıflandırması

Genel amaçlı, her ağı çalıştırabilen bir sistem hedeflenmiyor — kapsam bilinçli olarak dar ve
derin (Abstract §2).

## Girdi formatı: neden RGB (kapatıldı 2026-08-28)

MVP spesifikasyonundaki **32×32 grayscale** girdi MNIST döneminden mirastı ve böcek türü
sınıflandırması için yanlıştı: böcek türlerini ayırt eden bilgi büyük ölçüde **renkte ve ince
dokuda**. Grayscale'e çevirmek renk kanalını tamamen atıyor, 32×32'ye indirmek dokuyu yok
ediyordu. Bu ikisi birleşince model doğruluğu donanımdan bağımsız olarak düşük kalır — ve
Abstract §2 açıkça "düşük performanslı, kullanışsız tasarım kabul edilmez" diyor. Suç donanımda
olmasa da sonuç öyle görünürdü.

**RGB'ye geçmenin donanım maliyeti pratikte sıfır:**

| Etki alanı | Değişim |
|---|---|
| İlk conv katmanı | `c_in = 1` → `c_in = 3`. [[ADR-011 Ağırlık Bellek Adresleme\|ADR-011]]'in `K = c_in·kH·kW` formülü bunu zaten kapsıyor — **RTL değişikliği yok**, sadece parametre |
| Frame boyutu | 1024 → **3072 byte**. 64-bit TDATA'da tam **384 beat**, kalansız — [[ADR-006 AXI Stream Paket Semantiği\|ADR-006]] değişmiyor, TKEEP hâlâ sabit all-1 |
| Ağırlık BRAM | İlk katmanın `K` değeri 3× büyür; sonraki katmanlar etkilenmez. BRAM bütçesinde sorun yok |
| Systolic array | Etkilenmiyor — `c_in` yalnızca indirgeme uzunluğunu (`K`) değiştirir, [[ADR-004 Systolic Array Boyutu\|ADR-004]] sabit |

Çözünürlüğü artırmak (64×64) ise line buffer derinliğini iki katına çıkarır — bu gerçek bir
maliyet. Huynh 64×64 ve 128×128'in PYNQ-Z2'ye sığdığını gösterdi, yani kapı açık; ama Aşama
1'de 32×32'de kalınıyor, çözünürlük ancak doğruluk yetersiz kalırsa artırılacak.

**Karar sırası önemli:** önce renk (bedava), sonra gerekirse çözünürlük (maliyetli).

## Gerekçe (topoloji)
- LeNet-5 küçük, iyi belgelenmiş, orijinal makalesi mevcut (LeCun 1998) ve conv + pooling + FC
  üçlüsünü içerdiği için donanım veri yolunun tamamını egzersiz ettiriyor.
- Tek sabit topoloji seçmek, eforu tek bir pipeline'da yoğunlaştırma kararının (Abstract §2)
  doğrudan sonucu.
- MNIST'i ara basamak olarak tutmak, model tarafında bilinen-iyi bir referans bırakıyor:
  hedef veri setinde doğruluk düşerse, sorunun quantization/donanımda mı yoksa veri setinde mi
  olduğu MNIST ile ayrıştırılabilir.

## Sonuçlar
- `c_in` ve girdi boyutu RTL'de **parametre** kalacak, sabit kodlanmayacak — çözünürlük
  artışı ihtimali için kapı açık kalıyor.
- Kişi A'nın veri hazırlama hattı RGB üretecek; normalizasyon katsayıları kanal başına
  ayrı tutulacak ve model checkpoint'iyle birlikte kaydedilecek (Roadmap §4.1).
- Aşama 3'te (RFF) topoloji yeniden değerlendirilecek — bkz. [[Kontrat Değerlendirmesi]] ve
  `ADR-013` (skip connection desteği).
