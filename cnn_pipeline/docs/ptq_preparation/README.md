# INT8 PTQ ve integer golden reference hazırlık raporu

İnceleme tarihi: **22 Eylül 2026**. Kapsam: mevcut dosyaların, yerel Python
ortamının, seçilen FP32 checkpoint'in ve kabul edilmiş ADR'lerin incelenmesi.

**Sonuç:** FP32 altyapısı PTQ geliştirmesine başlamak için yeterli. Ancak henüz
çalışan bir PTQ, integer inference veya RTL karşılaştırma paketi yok. Temel
sayısal format zaten kontratlarda kararlaştırılmış; calibration, bazı sayısal
uç durumlar ve dosya/stream arayüzü tamamlanmalı.

Bu çalışmada yalnız bu rapor oluşturuldu. Eğitim, calibration, quantization,
FP32/test doğruluk değerlendirmesi veya test paketi çalıştırılmadı. Kod,
checkpoint, veri ayrımı ve bağımlılıklar değiştirilmedi; commit/push yapılmadı.
Katman boyutları, checkpoint'in belleğe salt okunur yüklenmesi ve sıfır girdili
tek FP32 inference ile kontrol edildi. Bu bir calibration çalışması değildir.

## 1. Kaynaklar ve kararların anlamı

Bu raporda üç statü kullanılır:

- **Doğrulandı:** mevcut kod/checkpoint veya yerel ortam üzerinde görüldü.
- **Kontratta kesin:** kabul edilmiş ADR'de yazılı; RTL'nin gerçekten bunu
  uyguladığı ayrıca doğrulanmış değildir.
- **Açık / öneri:** henüz ortak karar veya uygulanmış davranış değildir.

Başlıca yerel kaynaklar:

- [model.py](../../model.py), [data.py](../../data.py),
  [compute_stats.py](../../compute_stats.py), [train.py](../../train.py),
  [analyze_validation.py](../../analyze_validation.py).
- [Seçilen model kaydı](../accuracy_improvement/selected_model.json),
  [FP32 değerlendirmesi](../accuracy_improvement/README.md),
  [seed tekrarı](../seed_repeat/README.md).
- [ADR-002: topoloji](../../../Kontratlar/ADR-002%20CNN%20Topolojisi%20ve%20Dataset.md),
  [ADR-003: sayısal format](../../../Kontratlar/ADR-003%20INT8%20Fixed-Point%20Formatı.md),
  [ADR-005: direct convolution](../../../Kontratlar/ADR-005%20Direct%20Convolution.md),
  [ADR-006: stream](../../../Kontratlar/ADR-006%20AXI%20Stream%20Paket%20Semantiği.md),
  [ADR-009: doğrulama](../../../Kontratlar/ADR-009%20Doğrulama%20Ortamı.md),
  [ADR-011: ağırlık düzeni](../../../Kontratlar/ADR-011%20Ağırlık%20Bellek%20Adresleme.md).

Bu inceleme yerel kontrat kopyalarına dayanır; uzak repo veya arkadaşın
bilgisayarındaki RTL için güncellik/uygunluk doğrulaması yapılmadı.

## 2. PTQ için checkpoint adayı

**Aday değişmedi:** `resize_cosine`, seed 42, seçilen epoch 51.

| Kontrol | Sonuç |
|---|---|
| Pipeline'a göre yol | `outputs/resize_cosine_60epochs/insects/best.pt` |
| Tam yerel yol | `/home/cgj/Desktop/OpenSource-Grad-Project/cnn_pipeline/outputs/resize_cosine_60epochs/insects/best.pt` |
| Yerelde mevcut mu? | Evet |
| Dosya boyutu | 253.269 byte |
| SHA256 kayıtla aynı mı? | Evet |
| State dict yükleme | `strict=True` ile başarılı |
| Parametreler | 62.006; tamamı FP32 ve sonlu |
| Giriş / çıkış | `[1,3,32,32]` → `[1,10]` |
| Kaynak kod kimliği | `train.py`, `data.py`, `model.py` hash'leri checkpoint kaydıyla eşleşiyor |

Doğrulanan SHA256:

```text
9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e
```

Bu, seed 123 tekrar checkpoint'i veya ilk 30 epoch baseline'ı değildir.
Seed 123 koşusu validation accuracy %54,62 ve macro recall %37,69 verdi;
seçilen seed 42 adayı değiştirilmedi. PTQ'nun başlangıcında dosya kimliği yeniden
kontrol edilmeli; kopyası/çıktıları farklı konuma yazılmalı.

**Mevcut raporlardan alınan ölçümler; bugün yeniden hesaplanmadı:**

| Ölçüm | Seçilen FP32 model |
|---|---:|
| Validation accuracy | %55,4115 |
| Validation macro recall | %40,3275 |
| Test accuracy | %51,5394 |
| Test macro recall | %36,4453 |

FP32 testte `bug` ve `fly_sarco` recall'u sıfır. Bu nedenle PTQ'da kayıp
ölçmekle mevcut sınıflandırma kalitesini kabul etmek farklı kararlardır.
INT8'e geçiş FP32 modelin veri/etiket sorunlarını kendiliğinden çözmez.

## 3. Veri ve preprocessing

Dosya sayıları manifest ile eşleşiyor: **7.297 train, 1.774 val, 1.624 test**.
Split manifest SHA256:

```text
fd7fbe0b975f2c792cce5795836fd2708f66b1ff822759616e512dda4ffece7a
```

Veri ayrımı çekim günü bazında yapılmış; aynı gün farklı kümelere dağıtılmıyor.
Bu, gerçek böcek kimliği bazında bağımsızlık garantisi değildir. Kalibrasyon
alt kümesi oluşturmak, mevcut train/val/test ayrımını değiştirmek değildir.

Sınıf sırası sabittir:

```text
0 bee               1 beetle          2 beetle_cocci
3 bug               4 fly             5 fly_sarco
6 fly_small         7 hfly_episyr      8 hfly_eupeo
9 hfly_sphaero
```

Checkpoint ile `data/insects/stats.json` değerleri birebir eşleşiyor:

| Kanal | Mean | Std |
|---|---:|---:|
| R | 0.4525560220366023 | 0.22734425304237743 |
| G | 0.4813439340749695 | 0.2079375971691783 |
| B | 0.19916884506781363 | 0.2056275746970152 |

Mevcut değerlendirme: ImageFolder ile RGB → bilinear `Resize(32,32)`,
`antialias=True` → `ToTensor` (0–1) → `(x-mean)/std` → NCHW float32.
Normalize edilmiş giriş negatif olabilir. RGB kanalına ayrı mean/std olması,
**giriş quantization scale'inin kanal başına olması demek değildir**;
ADR-003 giriş dahil aktivasyon için per-tensor scale ister.

PTQ için mevcut train_loader doğrudan uygun değil: seçilen eğitimde crop
kaldırılmış olsa da RandomHorizontalFlip ve ColorJitter hâlâ var.
Calibration'da train dosyalarını değerlendirme dönüşümüyle, `eval()` ve
`inference_mode()` altında, shuffle olmadan yüklemek gerekir. Bunun ayrı bir
calibration arayüzü henüz yok. `_limited()` alfabetik veri sırasının ilk N
örneğini alır; `--limit-train 1000` gibi bir kullanım sınıfları yeterince temsil
etmeyebilir. Modelde BatchNorm/Dropout olmasa da değerlendirme modu açık olmalı.

**Öneri, henüz karar değil:** ilk calibration adayında train'den 100 görüntü ×
10 sınıf = 1.000 görüntü; sınıf içinde farklı çekim günlerine yayılmış, sabit
seed'li ve dosya yolları/hash'leri kayıtlı seçim. Her sınıfta yeterli train
örneği var. Dengeli seçim gerçek kullanım dağılımının aynısı olmayabilir;
kapsam ve sayı, validation sonuçlarıyla değerlendirilmeli. Observer türü için
başlangıç adayı min/max; percentile/histogram clipping seçilmiş değil.

Validation kalibrasyon parametreleri karşılaştırması için, test ise PTQ tarifi
sabitlendikten sonraki son değerlendirme için ayrılmalı. Bugün hiçbiri üzerinde
calibration veya yeni doğruluk hesabı yapılmadı.

## 4. Katmanlar ve tensor boyutları

Batch 1, NCHW. Aşağıdaki boyutlar FP32 model üzerinde doğrulandı.
Conv'larda kernel 5×5, stride 1, padding 0, dilation 1, groups 1 ve bias var.
Pool'larda kernel/stride 2, padding 0, ceil_mode=False. Linear katmanlarında
bias var. Son katmandan sonra ReLU veya Softmax yok; çıkış ham logit.

| Modül | İşlem | Giriş | Çıkış | Ağırlık şekli |
|---|---|---|---|---|
| `features.0` | Conv1 | 1×3×32×32 | 1×6×28×28 | 6×3×5×5 |
| `features.1` | ReLU | 1×6×28×28 | aynı | — |
| `features.2` | MaxPool | 1×6×28×28 | 1×6×14×14 | — |
| `features.3` | Conv2 | 1×6×14×14 | 1×16×10×10 | 16×6×5×5 |
| `features.4` | ReLU | 1×16×10×10 | aynı | — |
| `features.5` | MaxPool | 1×16×10×10 | 1×16×5×5 | — |
| `classifier.0` | Flatten | 1×16×5×5 | 1×400 | — |
| `classifier.1` | FC1 | 1×400 | 1×120 | 120×400 |
| `classifier.2` | ReLU | 1×120 | aynı | — |
| `classifier.3` | FC2 | 1×120 | 1×84 | 84×120 |
| `classifier.4` | ReLU | 1×84 | aynı | — |
| `classifier.5` | FC3 | 1×84 | 1×10 | 10×84 |

61.770 ağırlık ve 236 bias var. Conv1/Conv2/FC1/FC2/FC3 için indirgeme
uzunlukları K sırasıyla **75, 150, 400, 120, 84**.

Quantization açısından gereksinimler:

- **Conv/Linear:** ağırlıklarda çıktı ekseni 0 boyunca scale; INT8 çarpımları
  geniş accumulator'da toplanır, kanal bias'ı eklenir ve kanal `(M0,n)` ile
  ortak çıktı scale'ine dönülür. Conv işlemi PyTorch ile aynı kernel yönünü
  kullanmalı (cross-correlation; filtreyi ters çevirmemeli).
- **ReLU:** ayrı ağırlığı yok. ADR-003'te requantization sonrası saturation alt
  sınırı 0 yapılarak uygulanır. Signed INT8'in burada yalnız 0…127 bölümü kullanılır.
- **MaxPool:** aynı pozitif scale/zero-point ile integer maksimum seçimi
  yapılabilir; ortalama ve yeni çarpan gerektirmez. Pool giriş/çıkışında aynı
  scale'i koruma önerisi ve requantization'a göre yeri RTL ile yazılı sabitlenmeli.
- **Flatten:** aritmetik yok; NCHW'de kanal, satır, sütun sırasını korur.
  CHW/HWC uyuşmazlığı bütün FC ağırlık eşleşmesini bozar.
- **FC3:** negatif logit korunmalı, ReLU eklenmemeli. Son çıkışın INT8 mi,
  accumulator mı, yoksa yalnız argmax mı aktarılacağı arayüz kararıdır.

### Observer noktaları ve inplace ReLU riski

`ReLU(inplace=True)` mevcut Conv/Linear çıktısını yerinde değiştirir.
İleride hook içinde tensor referansı saklanıp sonra okunursa negatif Conv
çıktısı yanlışlıkla ReLU sonrası veri gibi görülebilir. Pre-ReLU ölçümünde
anında istatistik toplamak veya `detach().clone()` kullanmak gerekir.

Önerilen ölçüm noktaları: normalize giriş, Conv1/Conv2 pre-ReLU tanı çıktıları,
`features.1`, `features.4`, `classifier.2`, `classifier.4` ReLU çıkışları ve
`classifier.5` final logit. Pool/flatten scale aktarımı ayrıca kontrol edilmeli.
Hangi noktaların donanımda quantization sınırı olduğu önce ortaklaştırılmalı;
her hook çıktısı için otomatik olarak yeni bir scale üretmek doğru değildir.

## 5. Sayısal kontrat: kesinleşmiş olanlar

Aşağıdakiler yeni öneri değil, **ADR-003'ün kabul edilmiş kararlarıdır**:

| Başlık | Kontrattaki karar |
|---|---|
| Symmetric/asymmetric | Ağırlık ve aktivasyon simetrik; zero-point = 0 |
| Ağırlık scale | Per-output-channel; Conv ve Linear için eksen 0 |
| Aktivasyon scale | Per-tensor; bir aktivasyon tensorü için tek scale |
| Ağırlık / aktivasyon | Signed INT8 |
| Çarpım | Signed INT16, exact |
| Accumulator / bias | Signed INT32 |
| Bias ölçeği | Kanal başına `s_x * s_w[c]` |
| M0 | `[2^16,2^17)` pozitif değer; signed 18-bit register'da saklanır |
| Shift n | Unsigned 6-bit |
| Ara requant çarpımı | Signed 50-bit davranışı korunur |
| Requant yuvarlaması | Round-half-up: eşitlikte +∞ yönü |
| Çıkış saturation | ReLU varsa [0,127], yoksa [-128,127] |
| Python arithmetic | Python int veya np.int64; np.int32 çarpım yoluna güvenilmez |
| Bit-exact hedef | Integer golden ↔ RTL ↔ FPGA |

Scale, bir integer adımının temsil ettiği gerçek sayı miktarıdır:
`x ≈ s_x * (q_x - z_x)`. Bizde z_x=0. Scale değerleri **henüz hesaplanmadı**.
Signed dtype seçilmiş olması tek başına bütün scale/rounding ayrıntılarını çözmez.

Matematiksel zincir:

```text
q_x = clip(round_input(x / s_x), qmin, qmax)
q_w[c] = clip(round_weight(w[c] / s_w[c]), qmin, qmax)
q_bias[c] = round_bias(b[c] / (s_x * s_w[c]))
acc[c] = sum(q_x * q_w[c]) + q_bias[c]
M[c] = s_x * s_w[c] / s_y
M[c] ≈ M0[c] / 2^n[c]
y_raw = (acc[c] * M0[c] + 2^(n[c]-1)) >> n[c]
y_q = clamp(lo, 127, y_raw)
```

Bu açıklama kod uygulaması değildir. Özellikle `round_input`, `round_weight`
ve `round_bias` isimleri **açık kararları** gösterir. ADR yalnız requantization
rounding'ini kesinleştirmiştir. Örneğin half-up: +1,5 → +2; -1,5 → -1.
Python `round()` aynı kuralı genel olarak uygulamaz.

Asimetrik aktivasyon ADR'de geleceğe dönük alternatif olarak tartışılıyor;
mevcut kabul edilmiş tasarımın otomatik alternatifi değildir. Kullanılacaksa
kontrat değişikliği gerekir.

## 6. Açık sayısal kararlar ve uyumluluk riskleri

| Açık nokta | Neden önemli / kapatılacak karar |
|---|---|
| INT8 quantization aralığı | Depolama signed INT8 olsa da ilk input/weight quantizer -128…127 mi, simetrik dar -127…127 mi kullanacak? Çıkış saturation aralığı ADR'de zaten kesin. |
| Scale hesaplama yöntemi | Min/max observer türü, quant_min/max, reduce_range, epsilon, sıfır veya sabit kanal davranışı yazılmalı. Sayısal scale'ler calibration çıktısı olacak. |
| İlk float→integer rounding | Input, weight ve bias için tie kuralı açık değil; ayrı fonksiyonlar aynı sözleşmeyi kullanmalı. |
| Clipping | Sayısal saturation belli; calibration'da outlier clipping/percentile eşiği seçilmedi. Bunlar farklı kavramlar. |
| M → (M0,n) | Yaklaştırma algoritması, M0 yuvarlaması, normalize aralıktan taşma ve temsil edilemeyen multiplier davranışı tanımlanmalı. |
| n=0 | 6-bit alan 0'ı taşıyabilir ama ADR'deki `2^(n-1)` formülü n=0 için doğrudan uygulanamaz. Yasaklama veya özel yol kararı gerekli; n=63 de test edilmeli. |
| Bias sınırı | q_bias INT32 aralığı ve bias sonrası accumulator taşma politikası belirtilmeli. Sessiz wrap/saturation varsayılmamalı. |
| Katman sınırları | Requantization–ReLU–Pool sırası, pool'da scale'in korunması, final FC çıktı domain'i ortaklaştırılmalı. |
| Argmax | Final INT8 clipping/rounding eşit skorlar oluşturabilir; eşitlikte hangi sınıf seçilecek? |
| Kabul ölçütü | Accuracy ve macro recall'da kabul edilebilir kayıp henüz sayısal bir eşikle tanımlanmamış. |

Yerel observer kaynak kodunda simetrik scale paydası `(quant_max-quant_min)/2`.
-128…127 seçilirse bu 127,5 eder; elle yazılan `absmax/127` ile otomatik olarak
aynı değildir. Sadece “symmetric” demek yeterli değil; observer konfigürasyonu
ve export formülü birebir eşleşmeli. Bu incelemede observer yalnız import
edildi/kaynak okundu, tensor verilmedi ve qparam üretilmedi.

Max K=400 için, bias hariç kaba mutlak MAC sınırı
`400 × 128 × 128 = 6.553.600`; INT32 içine sığar. Ancak q_bias henüz bilinmediği
ve scale'ler seçilmediği için bütün accumulator yolunun taşmadığı bugün
kanıtlanmış değildir. INT64/Python int hesabı ardından INT32 aralık kontrolü
önerilir. `astype(int8)` öncesi clipping yapılmazsa saturation yerine wrap
üretilebilir; golden bunu açıkça engellemeli.

ADR'deki tie vektörü örneği doğrudan kopyalanmamalı: `acc` INT32 aralığında
kalmalı, n=0 ayrı ele alınmalı, hem tek hem çift M0 ve pozitif/negatif
saturation durumları kapsanmalı. Örnekteki modüler ters yöntemi tek M0 içindir.

## 7. Integer golden ve RTL ile ortak arayüz

Golden reference bir PyTorch quantized runtime çağrısının adı değildir.
Aynı INT8 dosyalarını okuyup integer Conv/FC, bias, requantization, ReLU ve
pooling'i açık aritmetikle uygulayan deterministik referans olmalı.
FP32 model ↔ dequantized INT8 yaklaşımı toleranslı; golden ↔ RTL birebir olmalı.
Accumulator taşmıyor ve ara saturation yoksa fiziksel MAC toplama sırasını
birebir taklit etmek gerekmez (Abstract'ın ayrımı).

### Zaten belirlenmiş arayüzler

- ADR-005: direct convolution; DDR'ye im2col matrisi export edilmeyecek.
- ADR-011: ağırlıklar `[out,in,kH,kW]`, kW en hızlı; FC `[out,in]` karşılığı.
- 8 banka: `bank=c_out%8`, `tile=c_out//8`, `addr=tile*K+k`,
  `k=c_in*kH*kW+kh*kW+kw`. **Ardışık dosyayı sekiz eşit parçaya kesmek değildir.**
- Katman başına 8 `.coe` dosyası.
- ADR-006: 64-bit TDATA, frame sonunda TLAST, TUSER yok, TKEEP sabit all-1.
  Mevcut RGB giriş 3.072 byte = **384 beat**.
- ADR-009: saf RTL için cocotb/Icarus; Xilinx IP entegrasyonu için XSim/SV;
  Python ile dosya üzerinden karşılaştırma. Burada belirtilenler ekip kontratıdır,
  bu incelemede simülatör uyumluluğu yeniden denenmedi.

### Arkadaşla açıkça kapatılacaklar

1. **Katman desteği:** yukarıdaki 5×5 Conv, max-pool 2×2, stride/padding,
   bias ve son FC'de ReLU olmaması RTL ile eşleşiyor mu?
2. **Tensor düzeni:** giriş/ara çıkış CHW mi HWC mi; flatten sırası ve katman
   isimleri ne? PyTorch NCHW olması AXI'nin aynı sırayı kullandığını kanıtlamaz.
3. **Byte/word düzeni:** ilk INT8 değer 64-bit word'ün hangi byte lane'ine gider?
   Hex satırı bir byte mı bir word mü; two's complement ve byte endianness nedir?
4. **Parametre yükleme:** bias_q, M0 ve n hangi dosya/register sırası, genişlik,
   signedness ve kanal/tile adresiyle yüklenir? M0 değeri pozitif olsa da
   signed 18-bit taşıyıcı gereksinimi korunmalı.
5. **Boş bankalar/partial tile:** Conv1'in 6, FC2'nin 84, FC3'ün 10 çıktısı için
   geçersiz kanallar maskelenir mi, sıfırla mı doldurulur; banka derinlikleri ne?
6. **Sayısal sınırlar:** n=0, q_bias rounding, accumulator overflow, output
   requantization ve pool scale politikası nasıl uygulanacak?
7. **Çıkış tipi:** 10 INT8 logit mi, INT32 accumulator mı, yalnız sınıf indeksi
   mi? Kanal başına scale'li ham accumulator değerleri ortak ölçeğe çevrilmeden
   doğrudan argmax için karşılaştırılamaz.
8. **Çıkış frame kuyruğu:** 10 INT8 logit 10 byte eder ve 8'e bölünmez. TKEEP
   all-1 korunacaksa 16 byte'a padding mi var? Son beat ve DMA byte sayısı ne?
   FC2 gibi ara tensor dump'larında da 8-byte hizası ayrıca düşünülmeli.
9. **Test dosyası protokolü:** `.coe` yanında `$readmemh` için `.mem/.hex`,
   dosya adları, eleman sayısı, beklenen shape, metadata ve ilk çalışan RTL
   modülünün komutu/commit'i ortaklaştırılmalı.
10. **Preprocessing sahibi:** RGB resize/normalizasyon ve giriş quantization'ı
    PS/Python'da mı? RTL ham uint8 görüntü mü, normalize edilip quantize edilmiş
    signed INT8 mi bekliyor? Aynı işlem iki kere uygulanmamalı.

Dokümanlarda iki örnek eskimesi var: ADR-005 gerekçesinde “LeNet 3×3” örneği
geçiyor ama kod **5×5**. ADR-006 gerekçesinde grayscale 1.024 byte/128 beat
örneği var; ADR-002 ve güncel model **RGB 3.072 byte/384 beat**. Bu rapor bu
belgeleri değiştirmedi; RTL ekibiyle yanlış örneğin uygulanmadığı kontrol edilmeli.

İleride paylaşılacak manifest için önerilen bilgiler: checkpoint ve veri
hash'leri, sınıf sırası, preprocessing, katman shape/layout/stride/padding,
qmin/qmax ve bütün rounding kuralları, scale/zero-point, kanal bias_q/M0/n,
scale aktarım noktaları, dosya düzeni, padding ve sürümler. Henüz böyle bir
PTQ/hardware manifest üretilmedi.

## 8. Bağımlılıklar ve mevcut kodun yeterliliği

İncelenen ortam: `/home/cgj/anaconda3/envs/pynq-cnn/bin/python`.

| Paket | Yerel sürüm / durum | PTQ etkisi |
|---|---|---|
| Python | 3.11.15 | Çalışan ortam |
| PyTorch | 2.11.0+cu128 | FP32 checkpoint yükleme ve observer importları başarılı |
| torchvision | 0.26.0+cu128 | Mevcut preprocessing çalışıyor |
| NumPy | 2.4.6 | Var; ama requirements.txt içinde doğrudan belirtilmemiş |
| Pillow | 12.3.0 | RGB görüntü yükleme/resize |
| pytest | 9.1.1 | Test altyapısı mevcut |
| torchao | Kurulu değil | Mevcut özel observer + integer yolunun başlaması için zorunlu değil |
| ONNX / ONNX Runtime | Kurulu değil | Bu plan için zorunlu değil |
| cocotb | Kurulu değil | Python PTQ'ya engel değil; RTL birim entegrasyonunda gerekecek |

**Eksik zorunlu çalışma paketi saptanmadı**; NumPy'nın doğrudan bağımlılık olarak
kayda alınması ve ortam sürümlerinin sabitlenmesi gerekiyor. requirements
aralıkları geniş; başka makinede aynı quantization API/sonucu garanti etmez.
Bugün paket kurulmadı, sürüm değiştirilmedi. CUDA paket etiketi, GPU'nun veya
kart üzerinde aynı Python ortamının kullanılabildiği anlamına gelmez.

Yerel `MinMaxObserver` ve `PerChannelMinMaxObserver` import edilebildi.
Varsayılanları **quint8 + affine**: ADR'ye uymak için dtype=qint8,
symmetric qscheme, ch_axis=0 (ağırlık) ve sayısal aralıklar açık verilmelidir.
Observer ekseni/parametreleri resmi sürüm dokümanında da belirtilir:
[PerChannelMinMaxObserver 2.11](https://docs.pytorch.org/docs/2.11/generated/torch.ao.quantization.observer.PerChannelMinMaxObserver.html),
[MinMaxObserver 2.11](https://docs.pytorch.org/docs/2.11/generated/torch.ao.quantization.observer.MinMaxObserver.html).

PyTorch ana quantization dokümanı geliştirmelerin torchao'ya taşındığını
belirtiyor. Bu nedenle eski eğitim örneklerinin API'lerini incelemeden kopyalamak
riskli; yerelde çalışan 2.11 observer arayüzü ile başlayıp kullanılan sürümü
kaydetmek daha kontrollü bir yol. Bu, torchao geçişinin bugün zorunlu olduğu
anlamına gelmez. [PyTorch quantization yönlendirmesi](https://docs.pytorch.org/docs/main/quantization).

ADR-003 FBGEMM'in aktivasyon signedness/rounding davranışına güvenerek golden
oluşturulmamasını özellikle istiyor. Backend desteği bugün quantized kernel
çalıştırılarak sınanmadı. Observer importunun çalışması uçtan uca INT8 backend
uyumluluğunu kanıtlamaz. `quantize_dynamic` ile yalnız Linear katmanlarını
çevirmek de iki Conv içeren sabit aktivasyon ölçekli donanım hedefini karşılamaz.
Modelde QuantStub/DeQuantStub veya qconfig yok; özel observer/export yolu için
bu tek başına engel değil. BatchNorm olmadığı için BN folding gerekmiyor.

Kodda hazır olanlar: FP32 model/checkpoint, sabit veri ayrımı, mean/std,
validation metrikleri ve pytest. Eksik olanlar: deterministic calibration
loader/manifest, observer bağlama, qparam üretimi, integer quantizer/requantizer,
integer Conv/Linear/Pool, bank export, katman dump ve RTL comparator.
`analyze_validation.py` FP32-only; INT8/golden karşılaştırıcısı yerine geçmez.

## 9. Test altyapısındaki boşluklar

Mevcut test dosyaları incelendi: model şekilleri/hatalı giriş, gün bazlı split,
sınıf ağırlıkları ve resize davranışı. Önceki çalışmada **17 test geçtiği**
kayıtlı; bugün tekrar çalıştırılmadı. Bunlar INT8 bit doğruluğunu test etmiyor.

Yarın ve sonraki uygulamada gerekli test grupları:

| Test | Kontrol edeceği davranış |
|---|---|
| Checkpoint/preprocessing | Hash, RGB mean/std, sınıf sırası, `[1,3,32,32]→[1,10]` |
| Calibration | Yalnız train yolları; sınıf/gün kapsaması; augmentation yok; tekrar üretilebilir örnek listesi |
| Observer sınırları | Inplace ReLU alias hatası; pre/post-ReLU ayrımı; per-channel eksen; all-zero kanal; NaN/Inf ve pozitif scale |
| Quantizer | qmin/qmax, -128/-127 tercihi, yarım değer rounding, clip-before-cast |
| Bias | Kanal scale çarpımı, tie kuralı, INT32 sınır ve taşma reddi/politikası |
| `T_NUM_REQ_001` | ±tie, INT32 sınırları, saturation uçları, n=0 politikası ve n=63, M0 aralığı |
| Integer Conv/Linear | Küçük elle hesaplanabilir örnekler; signed çarpma, bias, kernel yönü ve kanal sırası |
| Pool/Flatten | Max seçimi, scale'in korunması, CHW flatten sırası |
| Export | 8-bank export/import round-trip, partial tile, two's complement, dosya uzunlukları |
| Golden/RTL | Aynı input/parametrelerde bit-exact; ilk farklı katman/indeks/değer; eksik/fazla çıktı reddi |

Golden çıktıları yalnız kendi fonksiyonuyla tekrar hesaplayıp karşılaştırmak
yeterli değil; bağımsız küçük el hesapları ve kasıtlı köşe durumları olmalı.
PyTorch FP32 ile integer Conv karşılaştırması gerekiyorsa representable
integer örnekler veya açık tolerans kullanılmalı.

## 10. FP32–INT8 değerlendirme planı

Henüz INT8 sonucu yok. Planlanan karşılaştırmalar:

1. **Görev başarısı:** aynı validation örneklerinde accuracy ve macro recall
   farkı (yüzde puan), sınıf bazında recall ve confusion matrix.
2. **Tahmin uyuşması:** FP32/INT8 argmax agreement ve hangi görüntülerde
   kararın değiştiği. Accuracy aynı kalsa bile farklı hatalar olabilir.
3. **Sayısal hata:** aynı gerçek ölçeğe dequantize edilmiş katmanlarda
   MAE, maksimum mutlak hata; gerekirse RMSE. Farklı scale'deki integerleri
   doğrudan float aktivasyonlarla çıkarmamak gerekir.
4. **Quantization tanıları:** katman başına clipping/saturation oranı,
   sınır değerler, sıfır kanallar, `(M0,n)` yaklaştırma hatası ve final logit tie sayısı.
5. **Donanım doğruluğu:** golden/RTL ham integer değerler, dtype, shape ve
   dosya sırası birebir aynı olmalı; burada accuracy tek başına yeterli değil.

Kabul edilebilir accuracy/macro recall düşüşü kullanıcıyla sayısal olarak
belirlenmeli. Örneğin “en fazla 1 yüzde puan” yalnız tartışılabilecek bir
başlangıç önerisidir, mevcut kontrat değildir. Zaten zayıf sınıfların
bozulması ayrıca raporlanmalı. QAT'ye otomatik geçiş kararı yok.

Calibration/tarif seçenekleri train/validation üzerinden seçildikten sonra
FP32 ve INT8 aynı test kümesinde son kez karşılaştırılabilir. Test üzerinden
checkpoint veya scale yöntemi seçilmemeli. Bugünkü kayıtlı FP32 test metriği
bir referanstır; bugün yeni test çalıştırılmadı.

## 11. Yarın nereden başlanmalı?

**İlk uygulama adımı:** seçilen checkpoint/hash ve preprocessing'i doğrulayan,
train dosyalarını rastgele augmentation olmadan yükleyen ayrı calibration
girişi ve tekrar üretilebilir örnek manifest'i hazırlamak. İlk küçük kontrol:
aynı görüntü iki geçişte aynı float tensorü vermeli, model `[1,10]` üretmeli,
checkpoint değişmemeli. Bu, tam ağı bir anda quantize etmekten önce veri
akışını sabitler.

Öncesindeki kısa karar görüşmesinde qmin/qmax, ilk rounding kuralları,
calibration örnek sayısı/yöntemi ve değerlendirme sınırı kapatılmalı.
Ardından agreed observer noktalarında FP32 istatistik toplama ve qparam
üretimine geçilebilir. RTL arayüzü henüz kapanmadıysa gözlem raporu üretmek
mümkün; bunu bit-exact donanım paketi diye teslim etmek mümkün değil.

Golden tarafında ilk küçük uygulama **`requant_ref` + `T_NUM_REQ_001`** olmalı;
ADR'nin de önceliği bu. n=0 ve overflow gibi açık durumlar kapatıldıktan sonra
küçük Conv/Linear testlerine, sonra tam ağa geçilir. Bu dosyada bu uygulamalardan
hiçbiri başlatılmadı.

### Kullanıcıdan gereken kararlar

- Bu seed 42 checkpoint'inin PTQ referansı olarak kullanılacağını teyit etmek;
  mevcut düşük FP32 başarıyla donanım doğrulama hedefinin kapsamını ayırmak.
- Accuracy/macro recall için kabul edilebilir PTQ kaybını belirlemek.
- Önerilen train-only, gün çeşitliliği korunan 1.000 örneklik calibration
  başlangıcını veya farklı bir sayı/dağılımı seçmek.

### Donanım geliştiricisinden gereken kararlar

- Öncelikle 5×5/MaxPool desteği ve kesin katman zinciri.
- Tensor/flatten sırası, 64-bit byte lane düzeni ve preprocessing sınırı.
- Bias/M0/n formatı, n=0/overflow politikası, requant–ReLU–Pool sırası.
- Son katman çıktı tipi, padding/TKEEP/TLAST ve argmax tie davranışı.
- Banka boşlukları, `.coe`/`.mem` dosya sözleşmesi ve ilk test edilebilir RTL
  modülü/çalıştırma komutu. Kullanılan araç sürümleri de ADR-001'deki Vivado
  2024.1/PYNQ v3.1 kararıyla karşılaştırılmalı; yerel RTL araçları bugün denetlenmedi.

Bu kararlar raporda sorulacak maddeler olarak kaydedildi; hiçbiri sessizce
kesinleşmiş varsayılmadı.
