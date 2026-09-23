# FP32 aktivasyon ve ağırlık istatistikleri

24 Eylül 2026. Seçilen **seed=42, epoch=51** LeNet checkpoint'i üzerinde,
mevcut train-only **10 × 100 görüntülük** calibration seçimi kullanıldı.
Bu çalışma ham min/max/absmax ölçer; INT8 model/ağırlık, INT32 bias,
scale/qparam, M0/n veya `.coe` üretmez. Eğitim ve accuracy değerlendirmesi yoktur.

## Çalıştırma

Repo kökünden, mevcut `pynq-cnn` ortamında:

```bash
python cnn_pipeline/observe_activations.py \
  --checkpoint cnn_pipeline/outputs/resize_cosine_60epochs/insects/best.pt \
  --selected-model cnn_pipeline/docs/accuracy_improvement/selected_model.json \
  --data-dir cnn_pipeline/data/insects \
  --selection-manifest cnn_pipeline/outputs/calibration/seed42_100perclass_20260924/selection_manifest.json \
  --batch-size 32 --threads 2 \
  --output-dir cnn_pipeline/outputs/activation_calibration/seed42_epoch51_run02
```

Output-dir yeni olmalı; mevcut dizinler reddedilir. CLI yalnız
`cnn_pipeline/outputs/activation_calibration/` altında çıktı yazar.
Koşu başarılı olursa `statistics.json` oluşturulur; `outputs/` Git tarafından
yok sayılır. Bugünkü koşu `seed42_epoch51_20260924_run01` dizinindedir.

CLI seçim seed'ini 42, sınıf başına örnek sayısını 100 olarak sabit tutar.
Python fonksiyonu küçük sentetik testler için farklı örnek sayılarını kabul
eder. Seçim ve preprocessing tamamen mevcut
[calibration.py](../../calibration.py) üzerinden gelir; yeniden tanımlanmadı.
100 örnek/sınıf hâlâ deneysel başlangıç ayarıdır, ADR kararı değildir.

## Kimlik ve bütünlük doğrulaması

- Checkpoint byte SHA256'sı `selected_model.json` ile eşleştirilir; seed ve
  epoch metadata'sı kontrol edilir. State dict `strict=True` ile yüklenir.
- Mevcut seçim manifest'inin byte SHA256'sı yanındaki `summary.json` ile
  doğrulanır. Bu nedenle iki calibration çıktı dosyası birlikte gereklidir.
- Loader yeniden aynı API ile oluşturulur. Ürettiği manifest mevcut manifest'le
  karşılaştırılır: sıralı örnek yolları/etiketler/görüntü hash'leri, seçim
  ayarları, split kimliği, preprocessing, sınıf sırası, kaynak ve ortam
  sürümleri dahil. Herhangi bir fark hata üretir; sessiz yeniden seçim yoktur.
  JSON biçimlemesi, kaydedilmiş byte hash'i doğruysa anlamsal eşleşmeyi bozmaz.
- Eski kaynak/ortam sürümü değişmiş olsa bile otomatik kabul edilmez; bu ilk
  uygulama kasıtlı olarak sıkı kimlik kontrolü kullanır.
- Mevcut `check_batches` shape/dtype/range/etiket kontrollerini çalıştırır.
  Ardından ayrı geçişte model yalnız train loader ile gözlemlenir.
- Model parametre/buffer'larının değişmediği ve koşu sonunda checkpoint
  dosyasının SHA256'sının korunduğu doğrulanır. Dosyaların okuma geçişleri
  arasında başka bir süreç tarafından değiştirilmediği varsayılır.

Doğrulanan checkpoint SHA256:

```text
9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e
```

Mevcut calibration selection_manifest SHA256:

```text
a741a55b8bb754c73e8a8b43e11851011a1dda2f3841bb07b3460477e68aef3e
```

## Ölçüm yöntemi ve sonuç

Model CPU'da `eval()` ve `torch.inference_mode()` altında çalışır. CLI
`deterministic_algorithms=True`, 2 CPU thread kullanır. Batch-size 32;
1.000 görüntü 32 batch oluşturur, son batch 8 görüntüdür. Donanımın batch=1
kontratını değiştirmez; FP32 farklı backend/batch boyutlarında bit-exact
sonuç garantisi ileri sürülmez.

Özel gözlemci her hook çağrısında FP32 tensorün bütün elemanlarından extrema
ve negatif eleman sayısını **anında** hesaplayıp Python skalerleri saklar.
Tensor referansı saklanmadığı için sonraki inplace ReLU önceki ölçümü
bozamaz. Hook'lar hata durumunda da `finally` ile kaldırılır. Çağıranın model
train/eval bayrakları işlem sonunda geri yüklenir; ağırlıklara yazılmaz.

| Gözlem noktası | Tensor shape | Min | Max |
|---|---|---:|---:|
| Normalize giriş | N×3×32×32 | -2.3148479 | 3.8945708 |
| `features.1` — Conv1 ReLU | N×6×28×28 | 0 | 5.0626240 |
| `features.4` — Conv2 ReLU | N×16×10×10 | 0 | 8.8953190 |
| `classifier.2` — FC1 ReLU | N×120 | 0 | 17.5652809 |
| `classifier.4` — FC2 ReLU | N×84 | 0 | 20.2448044 |
| `classifier.5` — FC3 logits | N×10 | -36.4021072 | 20.2208672 |

Son satır için **absmax=36.4021072**; max ile aynı değildir. JSON her
noktada min/max/absmax'ı ayrı saklar. Final 10.000 logit'in **6.258'i negatif**;
son katmana ReLU veya clamp eklenmedi. Bütün noktalarda 1.000 örnek görüldü.
NaN/Inf, boş observer ve sıfır aktivasyon aralığı saptanmadı.

Ağırlıklarda çıktı kanalı ekseni **0** korunur; diğer eksenler azaltılır.
Conv için `[out,in,kH,kW]`, Linear için `[out,in]`. Rapor 236 çıktı kanalının
min/max/absmax dizilerini ve 236 bias'ın FP32 değerini içerir.

| Katman | Shape | Kanal absmax'ları arasındaki min–max |
|---|---|---:|
| Conv1 `features.0` | 6×3×5×5 | 0.1401512–0.2160566 |
| Conv2 `features.3` | 16×6×5×5 | 0.1328159–0.2835942 |
| FC1 `classifier.1` | 120×400 | 0.0578282–0.4059560 |
| FC2 `classifier.3` | 84×120 | 0.0961156–0.4338590 |
| FC3 `classifier.5` | 10×84 | 0.2730991–0.4446023 |

Hiçbir ağırlık kanalında sıfır aralık veya tamamen sıfır değer görülmedi.
NaN/Inf ve boş tensor hata üretir. Sıfır/sabit aralık ise açık bayraklarla
raporlanır; epsilon veya yapay pozitif scale atanmaz. Negatif logit bulunmaması
başka bir koşuda uyarı üretir, negatif değer zorla oluşturulmaz.

## Scale aktarımı ve açık kararlar

Bu noktalar **gözlem noktalarıdır**, otomatik olarak kesin donanım quantization
sınırları değildir. Önerilen aktarım:

- Conv1 ReLU sonrası scale/zero-point, `features.2` MaxPool boyunca korunur.
- Conv2 ReLU sonrası scale/zero-point, `features.5` MaxPool ve `classifier.0`
  Flatten boyunca korunur. Flatten CHW eleman sırasını değiştirmeden düzleştirir.

Pozitif ortak scale ile MaxPool yalnız maksimum elemanı seçer; Flatten
aritmetik yapmaz. Bu nedenle bu işlemler tek başına yeni scale gerektirmez.
Pool/requantization yerleşimi ve gerçek RTL sınırları ayrıca ortaklaştırılmalı.
Final logits signed kalmalıdır; final çıktı aktarım tipi henüz kilitlenmedi.

ADR-003 symmetric signed INT8, zero-point=0, aktivasyonda per-tensor ve
ağırlıkta per-output-channel yaklaşımını belirler. Ancak şu ayrıntılar açıktır:

- İlk quantizer qmin/qmax aralığı ve observer paydası (örneğin absmax/127 ile
  absmax/127.5 aynı değildir).
- Input/weight/bias float→integer rounding; ADR'deki requant round-half-up
  kuralını bu işlemlere kendiliğinden taşımamak gerekir.
- Sıfır/sabit kanal için epsilon/fallback, outlier clipping stratejisi.
- Bias quantization, accumulator taşması, M0/n dönüşümü ve n=0 politikası.

Bu uygulama bir aday scale bile hesaplamaz; sayısal politika alanları JSON'da
`null`, `scales_computed=false` olarak kayıtlıdır. Min/max birikimi hareketli
ortalama, histogram veya clipping içermez. Calibration extrema'sı bütün
gelecekteki görüntülerin aralığını garanti etmez. Capture-day hâlâ gerçek
birey kimliği değildir; gün dengeli 1.000 örnek doğal dağılımın aynısı olmayabilir.

## Testler ve değişiklik kapsamı

Önce sentetik testler, ardından gerçek calibration koşusu çalıştırıldı:

```bash
cd cnn_pipeline
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -q -p no:cacheprovider
```

**51 test geçti: 33 mevcut + 18 yeni test durumu.** Yeni testler bağımsız
elle hesaplanabilen tensorler ve küçük geçici görüntü/checkpoint fixture'ları
kullanır. Gerçek veri gerekmez. Kapsam: extrema güncellemesi, kanal ekseni,
sıfır/sabit aralık, boş gözlem, NaN/±Inf, negatif final logit, inplace ReLU
alias davranışı, başarılı/hatalı hook temizliği, eval/inference, değişmeyen
model/checkpoint, aynı seçimle tekrar üretilebilirlik ve manifest/hash reddi.

Yalnız üç yeni kaynak/doküman dosyası eklendi:
[observe_activations.py](../../observe_activations.py),
[test_observe_activations.py](../../tests/test_observe_activations.py), bu README.
Calibration loader, model, data/train kodu, ADR'ler ve geçmiş raporlar değiştirilmedi.
Paket kurulmadı; commit/push/PR/merge yapılmadı.
