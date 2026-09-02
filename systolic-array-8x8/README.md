# 8×8 Output-Stationary Systolic Array RTL

Bu paket, PYNQ-Z2 / XC7Z020 hedefi için temiz-kaynak yazılmış, 64 PE'li parametrik bir
SystemVerilog başlangıç tasarımıdır. Varsayılan sayısal kontrat signed INT8 aktivasyon, signed INT8
ağırlık ve signed INT32 accumulator'dır.

## İçerik

- `rtl/pe_os.sv`: Yerel accumulator, A/B forwarding register'ları ve ayrı valid yolları olan PE.
- `rtl/systolic_array_os.sv`: Parametrik `ROWS×COLS` PE ağı; varsayılan 8×8.
- `rtl/systolic_tile_engine.sv`: Tile yakalama, row/column skew, clear/run/capture kontrolü ve
  partial-tile maskesi.
- `rtl/systolic_array_8x8.sv`: 64 PE'li sabit isimli Vivado synthesis top.
- `tb/tb_pe_os.sv`: PE signed-boundary, stall, bubble, clear ve flush testleri.
- `tb/tb_systolic_array_8x8.sv`: Tam 8×8, signed sınır ve partial-tile self-checking testleri.
- `model/verify_architecture.py`: Bağımsız cycle model ve golden matrix multiplication kontrolü.
- `vivado/check_synth.tcl`: XC7Z020 out-of-context synthesis; 64 DSP48 kullanımını zorunlu kılar.
- `tasarim-ve-repo-incelemesi.md`: Kararlar, repo karşılaştırması ve blok diyagramları.

## Arabirim özeti

`systolic_array_8x8` bir `start` isteğini yalnız `start_ready=1` iken kabul eder. Girişler A için
8×8, B için 8×8 row-major packed bus'tır. `active_rows`, `active_cols` ve `k_len` ile daha küçük
tile'lar çalıştırılabilir. Sonuç matrisi row-major 64×32 bit packed bus üzerinde tutulur;
`c_valid` ve `done` bir çevrimlik completion pulse'larıdır.

Bu geniş paralel tile portları doğrulama ve OOC synthesis içindir. Ürün entegrasyonunda bunların
önüne banked BRAM/URAM feeder ve arkasına output FIFO/AXI wrapper konmalıdır.

## Doğrulama

Bağımsız cycle model:

```powershell
python model\verify_architecture.py
```

Icarus Verilog ile PE testi:

```powershell
iverilog -g2012 -s tb_pe_os -o pe_test.vvp rtl\pe_os.sv tb\tb_pe_os.sv
vvp pe_test.vvp
```

Icarus Verilog ile 8×8 test:

```powershell
iverilog -g2012 -s tb_systolic_array_8x8 -o array_test.vvp `
  rtl\pe_os.sv rtl\systolic_array_os.sv rtl\systolic_tile_engine.sv `
  rtl\systolic_array_8x8.sv tb\tb_systolic_array_8x8.sv
vvp array_test.vvp
```

Vivado OOC synthesis:

```powershell
vivado -mode batch -source vivado\check_synth.tcl
```

Kabul şartı `DSP48E1=64` ve 100 MHz için negatif olmayan WNS'dir. `use_dsp` özniteliği tek başına
kanıt sayılmaz; Tcl kontrolü bu nedenle sentezlenmiş netlistte gerçek primitive sayısını denetler.

## Bilinen sınır

`systolic_tile_engine` her `start` için accumulator'ları temizler. `K > K_MAX` olduğunda K
boyutundaki birden fazla tile'ın sonuçlarını birleştirmek için output scratchpad'de harici
tile-accumulation veya PE'lere `acc_seed/load_seed` yolu eklenmelidir. AXI backpressure çekirdeğin
ortasında uygulanmaz; çalışma başladıktan sonra banked feeder'ın kesintisiz veri garantisi gerekir.
