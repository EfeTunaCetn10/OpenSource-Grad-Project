---
title: ADR-002 CNN Topolojisi ve Dataset
created: 2026-08-28
modified: 2026-09-25
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, ml, dataset]
---

# ADR-002: CNN Topolojisi ve Dataset

## Durum
Kabul edildi — 2026-09-25 (Aşama 1 kernel ve layer geometry'si revize edilerek kilitlendi;
RGB girdi kararı 2026-08-28'de kapatıldı)

## Karar (kesin kısım)
- **Topoloji:** LeNet-5 (2 conv + pooling + 3 FC), sabit boyutlu, tek precision
- **Precision:** INT8 ([[ADR-003 INT8 Fixed-Point Formatı|ADR-003]])
- **Batch:** 1
- **Sınıf sayısı:** 10
- **Girdi:** **32×32 RGB** (`c_in = 3`), INT8 kanal başına
- **Aşama 1 kernel:** **5×5**, stride 1, valid convolution (padding yok)
- **Pooling:** 2×2, stride 2
- **Feature map channel sayıları:** conv1 = 6, conv2 = 16
- **FC geometry:** `16×5×5 = 400` input → 120 → 84 → 10
- **Eğitim sırası:** Önce MNIST (Hafta 3, referans/doğrulama), sonra hedef veri seti (Hafta 4+)
- **Hedef veri seti:** Böcek türü sınıflandırması

Genel amaçlı, her ağı çalıştırabilen bir sistem hedeflenmiyor — kapsam bilinçli olarak dar ve
derin (Abstract §2).

### Aşama 1 referans layer geometry

| Layer | Output shape | Parametre |
|---|---:|---|
| Input | `32×32×3` | RGB, INT8 |
| Conv1 | `28×28×6` | `5×5`, stride 1, valid |
| Pool1 | `14×14×6` | `2×2`, stride 2 |
| Conv2 | `10×10×16` | `5×5`, stride 1, valid |
| Pool2 | `5×5×16` | `2×2`, stride 2 |
| FC1 | 120 | input `16×5×5 = 400` |
| FC2 | 84 | — |
| FC3 | 10 | class logits |

### Derived tile count — 8×8 array

Bu tablo kararın bağımsız bir hyperparameter'ı değil, yukarıdaki layer geometry ile 8×8
array'den türetilmiş planlama hesabıdır. Matrix mapping'de `M=output channel`,
`N=output position` (FC'de batch), `K=reduction length` alınır:

| Layer | `M×N×K` | Output tile | `K` chunk (`K_MAX=8`) | Micro-run (`M×N×K`) |
|---|---:|---:|---:|---:|
| Conv1 | `6×784×75` | `1×98 = 98` | 10 | 980 |
| Conv2 | `16×100×150` | `2×13 = 26` | 19 | 494 |
| FC1 | `120×1×400` | `15×1 = 15` | 50 | 750 |
| FC2 | `84×1×120` | `11×1 = 11` | 15 | 165 |
| FC3 | `10×1×84` | `2×1 = 2` | 11 | 22 |

Buradaki `FC1 = 15 tile`, yalnızca `ceil(120/8)` output-channel tile sayısıdır. Mevcut
RTL'nin `K_MAX=8` tile-engine sınırıyla `K=400` ayrıca 50 K chunk'a bölünür ve partial
sonuçların accumulation edilmesi gerekir. Önerilen K-streaming tasarımında bu 50 ayrı
`start` yerine tek output tile boyunca 400 cycle K akışı yapılır; o durumda hardware
output-tile invocation sayısı 15 olarak kalır.

Bu tablo Aşama 1'in **reference model** kontratıdır. Aşama 3'te RFF için kernel veya layer
geometry değişirse yeni model/export parametreleriyle yeniden değerlendirilir; RTL'nin
window generator'ı `kH`/`kW` parametrelerini hard-code etmemelidir.

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

### Neden 5×5, 3×3 değil

5×5 seçimi salt MAC sayısını minimize etmek için değil, Aşama 1'in öğrenme ve doğrulama
hedefini minimize etmek için yapıldı:

- Proje LeNet-5'i referans alıyor; klasik geometry, `32 → 28 → 14 → 10 → 5` akışıyla
  `FC1 input = 400` sonucunu veriyor.
- Mevcut RTL performance analizi zaten `conv1 K=75`, `conv2 K=150`, `FC1 K=400` varsayımına
  dayanıyor. Bunlar RGB + 5×5 geometry ile birebir örtüşüyor.
- 3×3 valid convolution seçilirse geometry `32 → 30 → 15 → 13 → 6` olur ve `FC1 input`
  576'ya çıkar. Conv MAC'i azalırken maliyetin bir bölümü batch=1 nedeniyle verimsiz olan
  FC1'e taşınır; bu, mevcut accelerator için yalnızca “daha küçük kernel” değildir, farklı
  bir modeldir.
- 5×5'in hardware maliyeti vardır: direct convolution için `kH-1 = 4` önceki row'un
  tutulması gerekir (3×3'te 2 row). Ancak 32×32 Aşama 1 input'unda bu maliyet, model
  geometry'sini ve doğrulama zincirini değiştirme maliyetinden düşüktür.

Bu nedenle 5×5, Aşama 1 için **project-level optimum** olarak seçildi. 3×3 yalnızca
“daha az MAC” ölçütünde üstündür; doğruluk, geometry ve entegrasyon riskini aynı anda
minimize ettiği gösterilmiş değildir.

## Sonuçlar
- `c_in` ve girdi boyutu RTL'de **parametre** kalacak, sabit kodlanmayacak — çözünürlük
  artışı ihtimali için kapı açık kalıyor.
- Kişi A'nın veri hazırlama hattı RGB üretecek; normalizasyon katsayıları kanal başına
  ayrı tutulacak ve model checkpoint'iyle birlikte kaydedilecek (Roadmap §4.1).
- Aşama 3'te (RFF) topoloji yeniden değerlendirilecek — bkz. [[Kontrat Değerlendirmesi]] ve
  `ADR-013` (skip connection desteği).
