# Multiplier temsil edilebilirlik analizi — candidate/diagnostic

Bu çalışma nihai hardware parametre üreticisi değildir. Mevcut aday ölçeklerden
`M[c] = s_x * s_w[c] / s_y` hesaplar; ağ çalıştırmaz, bias eklemez ve requantizer'a
bağlanmaz. Önce bağımsız sentetik testler, sonra mevcut qparam analizi çalıştırıldı.

## Kontrat ile deneysel analizin ayrımı

ADR-003: `65536 <= M0 < 131072`, unsigned 6-bit n taşıyıcısı ve signed 50-bit
requantization ara işlemleri. Mevcut requant_ref yalnız n=1…49 destekler.
n=0'ın formülü kapanmamıştır; n=50…63 için `2^(n-1)` sabiti signed 50-bit'e
sığmaz. Bu modül diğer n değerlerini reddeder; RTL çözümü icat etmez.

**Aday analiz seçimi:** n=1…49 taranır; her n için `M*2^n` en yakın tamsayıya,
tie +∞ yönüne yuvarlanır. M0 aralığı dışındaki aday reddedilir. Kalan adaylarda
en küçük mutlak hata, eşit hatada küçük n seçilir. Bu seçim Kişi A/B tarafından
onaylanmış bir nihai M→M0/n algoritması değildir. Requantizer rounding kontratı,
multiplier oluşturma rounding kararını otomatik olarak kapatmaz.

Desteklenen uç değerler `65536/2^49 = 2^-33` ve `131071/2 = 65535.5`.
Dışındaki pozitif M için `unrepresentable`, boş aday listesi ve açıklama döner;
uçlara clamp yapılmaz. Aralıkta bulunmak tam temsil demek değildir. JSON her
kanalı `exact_float64`, `approximate_candidate` veya `unrepresentable` olarak
ayırır. Geçersiz/sonlu olmayan M için açık hata üretilir.

M0'ın 131072'ye yuvarlanması ilgili n için reddedilir ve normalize aralıkta ise
anomali olarak kaydedilir. Başka n geçerliyse ayrı aday olarak incelenir; örneğin
`M=131071.5/2^18` için n=18 reddedilir, n=17/M0=65536 adayının mutlak hatası
`2^-19` olur. Gizli clamp veya sessiz renormalizasyon yoktur.

Elle doğrulama: M=0.5 → 65536/2^17; M=0.25 → 65536/2^18. İkisi de tamdır.
`M_approx=M0/2^n`, mutlak hata `abs(M_approx-M)`, göreli hata `abs_error/M`.
Python float (binary64) çarpım/bölme ve hata hesabı kullanılır. `exact_float64`
yalnız hesaplanan binary64 M ile eşitliği ifade eder; gerçek sayı veya decimal
ölçekler üzerinde bit-exact iddia değildir. Ölçek çarpımı/bölümü underflow ile
sıfır veya overflow ile Inf üretirse reddedilir.

## Aday katman eşlemesi

`model.py` ve bias quantization dokümanındaki input eşlemesi kullanıldı:

| Katman | s_x gözlem anahtarı | s_y gözlem anahtarı | Weight anahtarı / kanal |
| --- | --- | --- | --- |
| Conv1 | input | features.1 | features.0 / 6 |
| Conv2 | features.1 | features.4 | features.3 / 16 |
| FC1 | features.4 | classifier.2 | classifier.1 / 120 |
| FC2 | classifier.2 | classifier.4 | classifier.3 / 84 |
| FC3 | classifier.4 | classifier.5 | classifier.5 / 10 |

Pool/Flatten boyunca aynı scale/zero-point'in taşınması varsayımı korunur.
FC3 çıkışı final logits gözlemidir. Bunlar gözlemlenmiş qparam noktalarıdır;
nihai RTL quantization sınırları henüz onaylanmış değildir.

## Kaynaklar ve doğrulama

Girdi: `outputs/quantization/seed42_epoch51_candidate_run01/qparams.json`.
Ölçekler README'den kopyalanmaz. Dosya yoksa durulur. Qparam provenance içindeki
checkpoint, selected_model, statistics, calibration manifest, summary ve varsa
split manifest byte SHA256 değerleri doğrulanır. Checkpoint kimliği seçili model
ve calibration ile; statistics kimliği qparams ile karşılaştırılır. Seed=42,
epoch=51, train-only 1000 örnek, sınıf sırası, seçim/preprocessing kayıtları,
katman isimleri, native weight shape, axis, kanal sayısı ve sonlu pozitif scale
kontrol edilir. Scale'ler kaynak statistics absmax/127 değerleriyle de eşleşmelidir.
Mevcut weight artifact hash'i varsa doğrulanır. Bu adım yeni görüntü seçmez,
görüntü hash'lerini tekrar taramaz veya checkpoint forward çalıştırmaz.

Mevcut provenance mutlak dosya yolları içerir. Repo başka yere taşınmışsa eksik
kaynak hatası alınabilir; bu sürüm kaynakları tahmin ederek yeniden eşleştirmez.
Başlangıç ve analiz sonu hash'leri karşılaştırılır; kaynaklar değiştirilmez.

Çalıştırma (repo kökünden; output-dir yeni olmalı):

```bash
python cnn_pipeline/multiplier_analysis.py \
  --qparams cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json \
  --output-dir cnn_pipeline/outputs/multiplier_analysis/seed42_epoch51_candidate_run01
```

Yerel sonuç: `outputs/multiplier_analysis/seed42_epoch51_candidate_run01/diagnostic.json`.
Dosya kanal bazında M, tüm geçerli adaylar, seçilen analiz adayı, hatalar ve
anomali listesini içerir. Yalnız yeni run klasörüne yazılır; mevcut klasör
üzerine yazma reddedilir. Bu JSON hardware export veya register paketi değildir.

## Gerçek 236 kanalın sonucu

| Katman | M min…max | n min…max | Temsil edilemeyen | Maks. mutlak hata | Maks. göreli hata |
| --- | --- | --- | --- | --- | --- |
| Conv1 | 0.000848940…0.001308723 | 26…27 | 0 | 3.067861e-9 | 3.204403e-6 |
| Conv2 | 0.000595197…0.001270889 | 26…27 | 0 | 7.019452e-9 | 6.767770e-6 |
| FC1 | 0.000230591…0.001618757 | 26…29 | 0 | 6.890791e-9 | 7.235404e-6 |
| FC2 | 0.000656647…0.002964056 | 25…27 | 0 | 1.476305e-8 | 7.193444e-6 |
| FC3 | 0.001195924…0.001946951 | 26…26 | 0 | 6.973144e-9 | 5.324348e-6 |

236 kanalın tamamı yaklaşık adaydır; tam binary64 eşitliği 0, temsil edilemeyen
0, sınır/yuvarlama anomalisi 0. Maksimum mutlak ve göreli hatalar farklı
kanallarda olabilir. Bu küçük multiplier hatası accuracy kanıtı değildir;
activation clipping henüz ölçülmedi ve toplam hata acc büyüklüğüne bağlıdır.

## Açık kararlar

Kişi A/B: M0 rounding, n seçimi ve üst sınırda yeniden normalizasyon/reddetme
politikası nihai üreticiden önce onaylanmalı. n=0 ve n=50…63 ile signed 50-bit
uyuşmazlığının RTL çözümü açık. Bias/MAC overflow ve gerçek katman quantization
sınırları ayrıca kapanmalı. Mevcut n aralığına sığan adaylar, RTL/FPGA bit-exact
uyumunun kanıtı değildir. Bias, inference, M0/n hardware export veya test vektörü
üretilmedi; mevcut modüller değiştirilmedi.

Test sonucu: **52 yeni sentetik test, tüm pakette 338 passed**. Testler tam
örnekleri, half-up/üst M0 sınırını, tüm dışlanan n değerlerini, sonluluk ve
pozitifliği, shape/kanal/anahtar uyuşmazlıklarını, sentetik dosya kimliği/hash
hatalarını, tekrarlanabilirliği ve değişmeyen girdileri kapsar. Gerçek dataset'e
bağımlı değildir. Sentetik provenance fixture'ı model çalıştırmaz.
