# Lane M6 Raporu — model/program (2026-11-14)

## Sonuç

B-05 ve B-06 host tarafı tamamlandı. Register map v5 tek JSON kaynağından SV/Python/C sabitlerine
üretiliyor. `netprog.py` model doğrulama, sekiz ağırlık bankası, katman/pass tablosu, tile parametreleri,
saf Python golden forward ve bölüm 6 program dosyalarını üretiyor. Sentetik v3 ağı ve iki seçilmiş v3
görüntüsü authority generator'dan import edildi. LeNet fixture da mevcut generator'dan import edildi;
FC1'in fiziksel `(tile,h,w,lane)` ağırlık sırası kontratın `(h,w,c)` sırasına kayıpsız çevrildi ve
`lenet_ref` logitleriyle bit-exact doğrulandı.

RTL yazılmadı ve var olan hiçbir dosya düzenlenmedi. Git komutu çalıştırılmadı.

## Yeni dosyalar

- `systolic-array-8x8/model/regmap.json`
- `systolic-array-8x8/model/gen_regmap.py`
- `systolic-array-8x8/model/netprog.py`
- `systolic-array-8x8/model/gen_netprog_vectors.py`
- `systolic-array-8x8/tb/accel_regs_pkg.sv` (üretilen)
- `systolic-array-8x8/sw/common/accel_regs.py` (üretilen)
- `systolic-array-8x8/sw/common/accel_regs.h` (üretilen)
- `systolic-array-8x8/sim/vectors/np_v3.prog`
- `systolic-array-8x8/sim/vectors/np_v3_in.mem`
- `systolic-array-8x8/sim/vectors/np_v3_exp.mem`
- `systolic-array-8x8/sim/vectors/np_v3_meta.json`
- `systolic-array-8x8/sim/vectors/np_v3_model.json`
- `systolic-array-8x8/sim/vectors/np_lenet.prog`
- `systolic-array-8x8/sim/vectors/np_lenet_in.mem`
- `systolic-array-8x8/sim/vectors/np_lenet_exp.mem`
- `systolic-array-8x8/sim/vectors/np_lenet_meta.json`
- `systolic-array-8x8/sim/vectors/np_lenet_model.json`
- `LANE-RAPOR-M6.md`

`sim/vectors` dosyaları repository'nin mevcut politikasında gitignored olabilir; generator bunları
yeniden ve deterministik üretir.

## Uygulama notları

- `regmap.json`, v4 başlık tablosunun tüm register/field alanlarını ve v5 `W_ADDR`/`W_DATA` eklerini
  `name`, `offset`, `access`, `bits` ile tutar. Generator template kütüphanesi kullanmaz.
- `gen_regmap.py --check`, eksik veya byte-for-byte stale üç çıktıdan herhangi birinde exit 1 verir.
- `netprog.py` register adreslerini ve field yerleşimlerini yalnız üretilen `accel_regs.py` üzerinden
  alır; host program kodunda literal register offset yoktur.
- Envelope kontrolleri: `K <= 1024`, bank başına `<= 8192` byte, `tiles*h*w <= 4608`,
  `M0 in [2^16,2^17)`, giriş `<= 48x48`, kernel `<= 5`, pad `<= 2`; ayrıca field genişliği,
  şekil, INT8/INT32 ve kaynak geometri kontrolleri uygulanır.
- v3 programı bank başına yalnız kullanılan 6086 byte'ı yükler: toplam 8 `W_ADDR` ve 48688
  `W_DATA`. İki görüntü için 54 pass, 54 COMMIT/START, 4 `S`, 4 `M` vardır.
- Selftest her görüntü için authority tablosundan bağımsız yeniden türetilmiş 27 pass'in beş config
  ve 24 param word'ünü karşılaştırır; iki görüntüde toplam 54 pass kontrol edilir.
- CLI ayrıca geçici bir model/images JSON çiftiyle doğrudan çalıştırıldı ve dört çıktısı doğrulandı.

## Kontratın pinlemediği sıra seçimleri

- Ağırlık yükleme bank sırası `0..7`; her bankta bir `W_ADDR(bank,0)` ve adres `0..6085` için ardışık
  `W_DATA` seçildi.
- Program başlangıcında önce VERSION okunuyor, sonra tüm banklar yükleniyor.
- Görüntüler `_in.mem` içinde ardışık HWC frame'lerdir. Aynı görüntünün conv1 tile pass'leri aynı
  frame offset'ini yeniden kullanır.
- `_exp.mem` görüntü-major, son katman tile-major tutulur. Her final tile için ayrı bir beat'lik `M`
  transferi başlatılır.
- Shadow yazım sırası TB ile aynı seçildi: `LAYER_CFG`, `LAYER_CFG2`, `W_BASE`, `TILE_CFG`, `DP_CFG`,
  ardından bank `0..7` için `BIAS_Q`, `M0`, `SHIFT|RELU`, sonra COMMIT.
- `LAYER_SWAP`, katmanın son tile pass'indeki W1C ve `J` bittikten sonra, sonraki katmanın config
  yazımlarından önce ayrı CONTROL yazımıdır. Son katmandan sonra swap yoktur.
- `IRQ_EN=0` bırakıldı; program polling kullanır. Global `ERROR` ve `ERR_DETAIL` kontrolleri bütün
  görüntüler bittikten sonra yapılır.
- Meta JSON için kontrat yalnız içerik başlıklarını verdiğinden `expected_argmax` görüntü listesi,
  görüntü başına logit `offset/nbeats/count`, açık lane tarifi ve input offset'leri seçildi.

## Acceptance — gerçek çıktılar

### 1. Register map stale kontrolü

Komut:

```text
python model/gen_regmap.py --check
```

Çıktı:

```text
PASS gen_regmap check
```

### 2. Program generator + selftest

Komutlar:

```text
python model/gen_netprog_vectors.py
python model/netprog.py --selftest
```

Çıktı:

```text
PASS gen_netprog_vectors: v3 2 images; LeNet 1 image, logits bit-exact
PASS netprog selftest: 8 banks, 7 layers, 54 passes, 2 images, 3 negative cases
```

Selftest negatifleri: M0 üst sınır ihlali, `K=1800 > 1024`, bank sonu `8518 > 8192`; üçü de
`ModelError` ile reddedildi.

### 3. Mevcut AXI-Lite regression

Komut:

```text
python sim/run_tests.py tb_axi_lite_regs
```

Çıktı:

```text
[xvlog] compiling 36 file(s)

  tb_axi_lite_regs  PASS

1/1 passed
```

Bu koşu yeni `tb/accel_regs_pkg.sv` dosyasını glob içinde derledi.

### Ek CLI smoke

Çıktı:

```text
PASS netprog emitted cli_v3
PASS netprog CLI smoke: 4 outputs
```

## Mutasyonlar

Mutasyonlar `model/netprog_mut_*.py` geçici kopyalarında çalıştırıldı ve sonra silindi; production
dosyası değiştirilmedi.

| Mutant | Selftest sonucu | Yakalayan kontrol |
|---|---|---|
| Bank seçimi `oc % 8` yerine `(oc // 8) % 8` | exit 1: `AssertionError: weight bank 0 differs` | Sekiz bankanın authority `v3e_wbank*.mem` ile byte karşılaştırması |
| FC flatten `(h,w,c)` yerine `(c,h,w)` | exit 1: `AssertionError: image 0 logits differ` | `v3_ref` forward logitlerinin authority `gen_v3_e2e_vectors.run_net` logitleriyle karşılaştırması |
| `last_rows = c_out % 8 + 1` | exit 1: `AssertionError: configure words differ from tb_v3_e2e.configure` | Authority layer tablosundan bağımsız türetilen 5+24 word/pass oracle |

Hayatta kalan mutant yoktur.

## Kontrata itiraz / açıklık

Önemli bir çelişki var: bölüm 5 örneği `weights` ve channel parametrelerinin tam `c_out` satır
olduğunu söylüyor; fakat bölüm D, banka görüntüsünün authority v3 bankalarıyla byte-identical olmasını
ve son fc2 tile'ın padded altı lane'indeki kasıtlı junk ağırlık/parametreleri de karşılaştırmayı istiyor.
`c_out` satırlı JSON bu byte'ları ifade edemez. Çözüm olarak loader hem `c_out` hem `ceil(c_out/8)*8`
satırı kabul eder; eksik padded satırları güvenli değerlerle doldurur, `np_v3_model.json` ise authority
junk byte'larını korumak için padded biçimi kullanır. Bu genişletme olmazsa byte-identical D maddesi
sağlanamaz.

Programın text işlem sırası pinli, fakat `_meta.json` anahtar adları/tipleri tam şemayla pinli değil;
yukarıdaki açık seçimler yapıldı. Lane S AXIS shell bu lane'de bulunmadığı için `.prog` dosyası RTL'de
replay edilmedi; bu doğrulama B-07/Lane T'ye bırakıldı. Kart, DMA, interrupt ve performans ölçülmedi.

## Orkestratöre tek satırlık ek

`sim/run_tests.py` içindeki `VECTOR_GENERATORS` listesine, mevcut LeNet girdisinden önce:

```python
("gen_netprog_vectors.py", "np_v3_meta.json"),
```
