# Deterministik calibration veri hattı

24 Eylül 2026 — bu adım yalnız **FP32 giriş verisini** hazırlar ve kontrol eder.
Model eğitimi, model forward/accuracy hesabı, observer, scale/qparam veya
quantized model üretimi yapmaz.

İlk deney ayarı **10 sınıf × 100 görüntü = 1.000 görüntü, seed=42**.
Bu sayı ve günleri gözeten dengeli örnekleme, deneysel başlangıç ayarıdır;
ADR-002/003'ün kabul edilmiş bir calibration kararı değildir. CLI diğer örnek
sayılarını da destekler; sınıf sayısını checkpoint belirler.

## Kullanım

Repo kökünden, mevcut `pynq-cnn` ortamıyla:

```bash
conda activate pynq-cnn
python cnn_pipeline/calibration.py \
  --checkpoint cnn_pipeline/outputs/resize_cosine_60epochs/insects/best.pt \
  --data-dir cnn_pipeline/data/insects \
  --samples-per-class 100 \
  --seed 42 \
  --batch-size 32 \
  --output-dir cnn_pipeline/outputs/calibration/seed42_100perclass_run02
```

`--checkpoint`, `--data-dir`, `--output-dir` zorunlu; diğer varsayılanlar yukarıdaki
değerlerdir. Yollar çalışma dizinine göre çözülür. Data-dir, `train/` klasörünün
üst dizinidir. Checkpoint ve görüntüler repo içinde olmalıdır; manifest yolları
repo köküne göredir. Dış veri depoları bu ilk sürümde desteklenmez.

Her koşu için **yeni output-dir** verilir; var olan dizin, boş olsa bile
reddedilir. CLI ayrıca veri dizininin altına çıktı yazmayı reddeder. Hiçbir
görüntü kopyalanmaz veya değiştirilmez. Seçim ve bütün batch kontrolleri
başarılı olduktan sonra yalnız belirtilen dizine iki dosya yazılır:

- `selection_manifest.json`: sıralı görüntü listesi, etiketler, görüntü SHA256'ları,
  capture-day, seed/strateji, checkpoint kimliği, split kimliği, preprocessing,
  kütüphane sürümleri ve ilgili kaynak kod hash'leri.
- `summary.json`: manifest dosyasının SHA256'sı, sınıf/gün sayıları, batch
  kontrolleri ve sınırlamalar.

Manifest SHA256'sı, `selection_manifest.json` dosyasının tam UTF-8 byte'larından
hesaplanır ve `summary.json` içinde saklanır. Hash'in kendi dosyasının içine
konmasıyla oluşacak kendine referans sorunu böyle önlenir. JSON anahtarları
sıralıdır; zaman damgası eklenmez. Aynı veri, checkpoint, kod, ortam ve seed ile
aynı seçim/sıra ve manifest byte'ları elde edilir. Batch-size seçimi değiştirmez.
Kod veya kütüphane sürümü değişirse provenance alanları nedeniyle manifest
hash'i değişebilir; bu, görüntü seçiminin mutlaka değiştiği anlamına gelmez.

`outputs/` mevcut `.gitignore` kapsamında; çalışma çıktıları Git'e eklenmez.

## Preprocessing neden ortak?

[calibration.py](../../calibration.py), [data.py](../../data.py) içindeki yeni
`build_insect_eval_transform(mean, std)` fonksiyonunu kullanır. Önceden
`build_insect_loaders` içinde yerel olan değerlendirme dönüşümü, davranışı
korunarak bu fonksiyona çıkarıldı. Var olan validation/test loader'ları da aynı
fonksiyonu çağırır; fonksiyon arayüzleri ve eğitim dönüşümü değişmedi.
Böylece iki ayrı resize/normalizasyon tarifi zamanla birbirinden uzaklaşmaz.

Akış: **PIL ile RGB → Resize(32,32), bilinear/antialias → ToTensor → Normalize**.
Mean/std doğrudan verilen checkpoint'ten okunur; `stats.json` ile değiştirilmez.
RandomHorizontalFlip, ColorJitter, RandomResizedCrop yoktur. Sonuç NCHW
`float32` tensorüdür. RGB yükleyicisi açıkça seçildiği için gri görüntüler de
üç kanala çevrilir.

Normalize edilmiş değerler 0–1 içinde olmak zorunda değildir. Her kanalda
beklenen sınır `-mean/std` ile `(1-mean)/std` arasındadır. Kontrol; shape,
dtype, sonluluk, bu aralıklar (1e-5 tolerans), etiket sırası ve toplam örnek
sayısını doğrular. Son batch atılmaz. DataLoader `shuffle=False`,
`num_workers=0` ve ayrı sabit seed'li generator kullanır.

Python arayüzü:

```python
from pathlib import Path
from calibration import build_calibration_loader, check_batches

bundle = build_calibration_loader(
    Path("outputs/resize_cosine_60epochs/insects/best.pt"),
    Path("data/insects"), samples_per_class=100, seed=42, batch_size=32,
)
checks = check_batches(bundle)
# bundle.loader: (images, labels); bundle.manifest: aynı sıradaki kayıtlar
```

Bu örnekte çalışma/import dizini `cnn_pipeline` olmalıdır. Loader oluşturmak ve
kontrol etmek dosya yazmaz; yazma CLI'nin son aşamasındadır. Checkpoint yalnız
CPU'ya salt okunur yüklenir; model ağırlıkları bu aşamada çalıştırılmaz.

## Seçim ve capture-day güven sınırı

1. Yalnız `data-dir/train` ImageFolder olarak açılır; val/test klasörlerine gerek
   yoktur. Checkpoint sınıf sırası ImageFolder'ın alfabetik indeksleriyle birebir
   karşılaştırılır. Uyuşmazlık veya yetersiz sınıf örneği hata üretir.
2. `split_manifest.json` varsa sınıf indeksleri ve train üyeliği mevcut train
   dosyalarıyla doğrulanır. Tekrarlanan kayıt veya çelişkili üyelik reddedilir.
   Val/test görüntüleri açılmaz; manifest'teki split etiketleri yalnız mevcut
   üyelik doğrulamasının parçasıdır. Yeni split yapılmaz.
3. Her sınıfın bütün adaylarında geçerli `day` (YYYYMMDD) ve SHA256 alanları
   varsa günler ve gün içi adaylar yerel seed'li RNG ile karıştırılır. Günlerden
   sırayla birer görüntü alınır; yeterli sayıya ulaşılana kadar dolu günlerle
   devam edilir. Aynı görüntü iki kez seçilmez.
4. Manifest yoksa veya sınıfın herhangi bir adayında güvenilir gün/hash bilgisi
   eksikse **o sınıfın tamamında** seed'li, tekrarsız rastgele seçim yapılır.
   Dosya adından gün türetilmez. Kullanılan strateji ve sınırlama manifest'e
   yazılır. Bozuk üyelik manifest'i sessizce bu yolla geçiştirilmez.
5. Seçilen bütün sınıflar birleştirilip aynı yerel RNG ile karıştırılır.
   Seçilen dosyaların gerçek SHA256'ları hesaplanır; kaynak manifest'te hash
   varsa eşleşmesi zorunludur. Train dışına çıkan symlink reddedilir.

Mevcut veri manifest'i [prepare_insect_detect.py](../../prepare_insect_detect.py)
ile hazırlanmış gün kayıtlarını içeriyor. Calibration kodu bu kaydı kaynak
kabul eder; günlerin fiziksel doğruluğunu bağımsız olarak kanıtlamaz. Kaynak
hazırlayıcı günleri orijinal isimlerden çıkarmıştı; burada yeniden isim
çözümlemesi yapılmaz. **Capture-day gerçek birey kimliği değildir**; günler
arasında yakın kopyalar bulunabilir. Günlere dengeli yayılım, doğal görüntü/gün
frekansını ve gerçek kullanım dağılımını aynen yansıtmaz.

Split kimliğinde kaynak manifest'in SHA256'sı ve sıralı train yol/etiket
envanterinin SHA256'sı bulunur. Kaynak manifest yoksa envanter hash'i kayıtlıdır
ama val/test ayrımının bağımsız doğrulaması yapılamaz; sınırlama belirtilir.
Seçilmeyen görüntülerin içerikleri hash doğrulaması için okunmaz. Dosyaların
seçim ve yükleme arasında değişmediği varsayılır.

## Doğrulama sonucu

Projenin pytest ayarını kullanarak:

```bash
cd cnn_pipeline
PYTHONDONTWRITEBYTECODE=1 python -B -m pytest -q -p no:cacheprovider
```

**33 test geçti** (17 mevcut + 16 yeni test durumu). Yeni testler küçük geçici
PNG klasörleri ve checkpoint metadata fixture'ları kullanır; gerçek dataset'e
veya seçilen checkpoint'e bağımlı değildir. Aynı/farklı seed, sıra, gün kapsaması,
train-only, augmentation yokluğu, RGB/shape/normalizasyon, sınıf sırası,
yetersiz örnek, eksik metadata fallback, üyelik/hash uyuşmazlığı, symlink,
manifest hash'i ve overwrite engeli kapsanır.

İlk pytest çağrısı repo kökünden yapıldığı için alt dizindeki `pytest.ini`
import ayarını kullanamadı ve collection hatası verdi. Yukarıdaki doğru çalışma
dizininde tüm paket başarıyla çalıştı; bunun için test yapılandırması değiştirilmedi.

Yerel smoke test çıktısı:
`outputs/calibration/seed42_100perclass_20260924/`.

| Kontrol | Sonuç |
|---|---|
| Seçim | Train'den 10 sınıf × 100 = 1.000 görüntü |
| Seed / batch-size | 42 / 32 |
| Okunan batch | 32; son batch 8 görüntü |
| Shape / dtype | `[N,3,32,32]` / float32 |
| Gözlenen normalize min / max | -2.3148479462 / 3.8945708275 |
| Gün seçimi | 10 sınıfın tamamında manifest tabanlı gün turu |
| Gün kapsamı | bee 43, beetle 34, beetle_cocci 17, bug 18, fly 45, fly_sarco 24, fly_small 42, hfly_episyr 44, hfly_eupeo 47, hfly_sphaero 18 |

Checkpoint SHA256 (seçilen model kaydıyla aynı):

```text
9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e
```

Seçim manifest SHA256:

```text
a741a55b8bb754c73e8a8b43e11851011a1dda2f3841bb07b3460477e68aef3e
```

Bu sonuç bir doğruluk veya INT8 kalite sonucu değildir. Mevcut checkpoint,
model mimarisi, train/val/test ayrımı, ADR'ler ve eski deney çıktıları
korundu. Paket kurulmadı; commit/push/PR/merge yapılmadı. Sonraki PTQ işlemleri
bu görevin kapsamı dışındadır.
