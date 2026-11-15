# Lane P6 Raporu — PYNQ driver / host Python (2026-11-14)

## Sonuç

B-09 tamamlandı. Frozen `W/R/P/S/M/J` programı, PYNQ import etmeden host fake'leriyle veya kartta
enjekte edilen MMIO/DMA/`allocate` collaborator'larıyla çalıştırılıyor. `S` ve `M` non-blocking
başlatılıyor; transfer bekleme ve output karşılaştırması yalnız `J` işleminde yapılıyor. Meta logit
dilimleri signed INT8 lane düzeniyle çözülüp first-maximum argmax sınıfları döndürülüyor.

Var olan dosya düzenlenmedi, RTL yazılmadı ve git komutu çalıştırılmadı.

## Yeni dosyalar

- `systolic-array-8x8/sw/pynq/accel_driver.py`
- `systolic-array-8x8/sw/pynq/run_network.py`
- `systolic-array-8x8/sw/pynq/test_driver_mock.py`
- `systolic-array-8x8/sw/pynq/README.md`
- `LANE-RAPOR-P6.md`

`sim/vectors/np_v3.*` acceptance öncesinde kontratta belirtilen `python model/gen_netprog_vectors.py`
komutuyla üretildi; generator çıktısı `PASS gen_netprog_vectors: v3 2 images; LeNet 1 image, logits
bit-exact` idi.

## Uygulama notları

- `AccelDriver(mmio, dma, allocate, compare=True, timeout=1.0)` dış bağımlılıkları enjekte eder;
  `accel_driver.py` module import sırasında `pynq` veya `numpy` import etmez.
- `.mem` kelimeleri 64-bit integer olarak okunur ve lane 0 düşük byte olacak biçimde contiguous
  byte buffer'a yazılır.
- `run_program()` alınan `M` kelimelerini program sırasıyla döndürür. `compare=False` golden data
  karşılaştırmasını kapatır fakat output toplamaya devam eder.
- `PollTimeout`, `RegisterMismatch` ve `DataMismatch` ham register değerleriyle birlikte üretilmiş
  `accel_regs.py` adlarıyla decode edilmiş `STATUS`, `ERROR`, `ERR_DETAIL` sözlüklerini taşır.
- `run_network.py`, aynı stem'e sahip `.bit`/`.hwh` çiftini zorunlu tutar, overlay içindeki varsayılan
  `accel_0` ve `axi_dma_0` bloklarını bulur, v5 `VERSION` kontrolü yapar ve ortalama per-image wall
  time ile dört hardware counter'ı basar.
- Host fake MMIO ve iki DMA kanalı bütün read/write/transfer/wait işlemlerini trace'e kaydeder. START
  sonrasında DONE üretir ve receive buffer'larını gerçek `_exp.mem` dilimleriyle doldurur.

## Acceptance — gerçek çıktılar

Vektör üretimi, `systolic-array-8x8/` içinden:

```text
> python model/gen_netprog_vectors.py
PASS gen_netprog_vectors: v3 2 images; LeNet 1 image, logits bit-exact
```

İstenen host testi:

```text
> python sw/pynq/test_driver_mock.py
PASS test_driver_mock: 50436 writes, 4 sends, 4 recvs, classify/timeout/R/M checks
```

Ek syntax ve host-side lazy-import smoke:

```text
> python -m py_compile sw/pynq/accel_driver.py sw/pynq/run_network.py sw/pynq/test_driver_mock.py
> python sw/pynq/run_network.py --help
usage: run_network.py [-h] [--accel ACCEL] [--dma DMA] [--timeout TIMEOUT]
                      [--no-compare]
                      bit program
```

Her üç komutun birleşik son koşusu exit 0 verdi. Test harness'ının ilk geliştirme koşusunda farklı
uzunluktaki trace tuple'larını comprehension başında unpack eden bir hata görüldü; filtre düzeltildikten
sonra yukarıdaki acceptance çıktısı iki ayrı koşuda tekrarlandı.

## Mutasyonlar

Mutasyonlar üç ayrı `sw/pynq_mut_*` scratch kopyasında uygulandı; production dosyaları değiştirilmedi
ve kopyalar koşulardan sonra silindi.

| Mutant | Gerçek sonuç | Yakalayan kontrol |
|---|---|---|
| `J` işlemi `join()` çağırmıyor | exit 1: `ProgramFormatError: ... outstanding DMA transfer(s); missing J` | Program sonunda outstanding DMA guard'ı; ayrıca test wait sayılarını denetler |
| `S` buffer'ı bir beat kısa (`words[:-1]`) | exit 1: `AssertionError`, `test_driver_mock.py` send byte-length assertion | Her `S` için kaydedilen transfer byte sayısı |
| `R` mismatch koşulu devre dışı | exit 1: `AssertionError: R mismatch was ignored` | Bilerek yanlış VERSION içeren negatif program |

Hayatta kalan mutant yoktur.

## Ölçülmeyenler

Kart olmadığı için README'deki “kartta henüz doğrulanmadı” listesi ölçülmedi: `pynq.allocate`
cache/flush davranışı, abort sonrası gerçek DMA reset/flush, gerçek MMIO latency ve PYNQ image ile
Vivado 2025.1 `.hwh` uyumluluğu. Bitstream/overlay yükleme, fiziksel DMA ve hardware counter değerleri
host fake testiyle doğrulanamaz.

## Kontrata itiraz / format sınırı

ADR-015, abort sonrasında yarım tile'ın W1C + COMMIT + START ile yeniden koşulmasını; `TLAST_LATE`
veya `dst_sel=1` abort durumunda ilgili DMA kanalının reset/flush edilmesini PS'ye yükler. Frozen bölüm-6
programı recovery branch/retry işlemi, mevcut pass'in `dst_sel` bilgisi veya DMA reset işlemi içermiyor.
PYNQ DMA nesnesi için portable bir channel-reset çağrısı da kontratta pinlenmemiştir. Bu nedenle sürücü
formatı genişletmeden otomatik recovery uydurmaz; hata snapshot'ıyla exception yükseltir. Kart bring-up
sırasında recovery, üst seviye politika ve gerçek PYNQ DMA API'si netleştirilmeden “doğrulandı” sayılamaz.

## Orkestratöre tek satırlık ek

Yok; `sim/run_tests.py`, `filelist.f` veya ortak kaynaklarda P lane için ek gerekmiyor.
