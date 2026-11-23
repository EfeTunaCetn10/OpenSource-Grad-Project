# PYNQ sürücüsü

Kartta aynı kök ada sahip `.bit` ve `.hwh` dosyalarını, üretilen `.prog`, `_in.mem`, `_exp.mem`
ve `_meta.json` dosyalarını aynı dizine kopyalayın. Bu dizine ayrıca `sw/pynq/accel_driver.py`,
`sw/pynq/run_network.py` ve `sw/common/accel_regs.py` dosyalarını kopyalayın. Örnek çalıştırma:

```text
python3 run_network.py design.bit np_v3.prog
```

Block-design adları farklıysa `--accel ad --dma ad` kullanılır. `--no-compare`, alınan DMA
çıktısını golden `_exp.mem` ile karşılaştırmadan sınıflandırır. Varsayılan poll timeout 1 saniyedir.

Hatalar:

- `PollTimeout`: bir `P` koşulu süre içinde oluşmadı.
- `RegisterMismatch`: bir `R` mask/value denetimi uyuşmadı.
- `DataMismatch`: `M` ile alınan kelimeler `_exp.mem` diliminden farklıydı.
- `ProgramFormatError`: frozen program sözdizimi, mem dilimi veya son `J` eksikti.

İlk üç hata ham ve register-map isimleriyle decode edilmiş `STATUS`, `ERROR` ve `ERR_DETAIL`
alanlarını taşır. Abort sonrasında ADR-015 gereği yarım kalan tile yeniden çalıştırılmalıdır;
`TLAST_LATE` veya `dst_sel=1` abort durumunda ilgili DMA kanalı ayrıca reset/flush edilmelidir.
Frozen program formatı recovery akışını tarif etmediği için bu sürücü otomatik recovery eklemez.

## kartta henüz doğrulanmadı

- `pynq.allocate` buffer cache/flush davranışı
- Abort sonrasında gerçek AXI DMA kanal reset/flush davranışı
- Gerçek AXI4-Lite MMIO latency
- Kullanılan PYNQ image ile Vivado 2025.1 `.hwh` uyumluluğu
