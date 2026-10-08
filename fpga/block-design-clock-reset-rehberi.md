# Block Design'da Clock/Reset Bağlantıları — PE ve 8×8 Array

Araştırma tarihi: 2026-09-11
Hedef: PYNQ-Z2 (`xc7z020clg400-1`), Vivado 2025.1, tek clock domain FCLK0 @ 100 MHz — [[ADR-001 Board ve Araç Sürümü|ADR-001]], [[ADR-008 Clock Domain Stratejisi|ADR-008]]

## Kök neden: neden hata alınıyor

`pe_os.sv` ve `systolic_array_8x8.sv` AXI olmayan, çıplak-port (raw port) modüller —
`clk`, `rst_n`, veri sinyalleri hepsi düz `logic`. IP Integrator (block design) clock/reset
bağlantılarını **interface** tipinden tanıyıp otomatik kurar (Connection Automation); düz
portları interface olarak görmez. Elle bağlarken en sık görülen üç hata:

1. PS'in `FCLK_RESET0_N` çıkışını (senkronize edilmemiş, serbest reset kaynağı) doğrudan PL
   mantığının `rst_n`'ine vermek. Bu, deassert kenarının PL clock'una göre asenkron kalması
   demektir — recovery/removal timing ihlali riski. Board'da "PE bazen resetten çıkmıyor"
   şeklinde görülür.
2. Polarite hatası: active-high bir reset sinyalini `pe_os`'un active-low `rst_n` portuna
   ters bağlamak → PE ya sürekli reset'te donuk kalır ya da hiç reset olmaz.
3. IP paketlerken `clk`/`rst_n` portlarını **Associate Clocks / Associate Resets** ile
   işaretlememek → Vivado bu portları düz tel sayar, Validate Design (F6) sonrası
   Connection Automation önerisi çıkmaz, "clock is not connected" uyarısı gelir.

## Terminoloji: bu projede "sync/async" ne anlama geliyor

- `pe_os` reset'i zaten **senkron**: `always_ff @(posedge clk) if (!rst_n) ...` — reset'in
  kendisi clk'e göre örnekleniyor. Bu, port seviyesinde zaten doğru.
- Roadmap §8.3'ün istediği şey farklı bir katman: reset **kaynağının** assert'i asenkron
  gelebilir (buton, power-on, PS soft-reset) ama **deassert** kenarı PE'nin clock'una göre
  senkronize edilmeli. Bunun hazır Xilinx bloğu **Processor System Reset** (`proc_sys_reset`,
  PG080) — async-assert/sync-deassert senkronizatörünü içeride kurar, elle FF zinciri
  yazmana gerek yok.
- Tek clock domain kararı (ADR-008) sayesinde PL içinde CDC senkronizatörüne hiç gerek yok;
  tek risk noktası PS↔PL reset senkronizasyonu, o da `proc_sys_reset` ile kapanıyor.

## Tek PE için minimal, doğru block design

Amaç: `pe_os`'u board'da tek başına çalıştırıp PS'ten `a_in/b_in/step/clear_acc` beslemek,
`acc_out`'u okumak.

1. New Block Design → ZYNQ7 Processing System ekle → **Run Block Automation** (PYNQ-Z2 board
   preset varsa otomatik gelir).
2. PS IP'sinde `PS-PL Configuration → General → Enable Clocks → FCLK_CLK0 = 100 MHz` açık
   olsun (ADR-008 hedefiyle birebir).
3. **Processor System Reset** IP'sini ekle:
   - `slowest_sync_clk` ← `FCLK_CLK0`
   - `ext_reset_in` ← PS bloğunun `FCLK_RESET0_N` çıkışı
   - `dcm_locked` ← sabit `1'b1` (ayrı bir PLL/MMCM yok, tek saat kaynağı zaten FCLK0)
   - Kullanılacak çıkış: `peripheral_aresetn` (active-low, FCLK0'a senkron deassert)
4. `pe_os`'u IPI'ye sokmanın iki yolu:
   - **(A) Önerilen — HDL wrapper, IP paketleme yok:** Block design'ı sadece PS + clock/reset
     üretmek için kullan; `pe_os`'u top-level HDL wrapper'da doğrudan instantiate et, BD'nin
     export ettiği `FCLK_CLK0` ve `peripheral_aresetn` sinyallerini oradan bağla. IPI
     karmaşıklığına hiç girmeden doğru clock/reset alınır — tek PE için en az hataya açık yol.
   - **(B) Tam IPI entegrasyonu:** `pe_os`'u Tools → Create and Package New IP ile paketle;
     paketleme sırasında `clk` portuna **Associate Clocks**, `rst_n` portuna
     **Associate Resets** işaretlemek zorunlu — aksi halde madde 3'teki hata çıkar. Diğer dar
     veri portlarını (a_in, b_in, step, clear_acc, pipe_flush, acc_out) test için 2-3 adet
     32-bit **AXI GPIO** üzerinden PS'e bağla.
5. Validate Design (F6) → Generate HDL Wrapper (**Let Vivado manage wrapper** — proje zaten
   Tcl olarak saklanacağı için, bkz. ADR-001, wrapper'ı elle kilitlemeye gerek yok) → XDC →
   bitstream.

## 8×8'e geçerken değişen şeyler

- Clock/reset tarafı **birebir aynı kalır**: aynı FCLK0 + aynı `proc_sys_reset` çıkışı array'in
  de `clk`/`rst_n`'ine gider. İkinci bir saat ağacı kurmaya gerek yok — ADR-008'in tam kazandırdığı şey bu.
- `systolic_array_8x8`'in 512/2048-bit flatten bus'ları AXI GPIO ile beslemek pratik değil;
  bu zaten README/Roadmap'in planladığı **AXI4-Lite/Stream + banked BRAM feeder** aşamasının
  (P1) neden gerekli olduğunu doğruluyor. Board'da erken bir "ışık yak" testi istiyorsan, tam
  genişlik yerine dar bir AXI4-Lite register seti + küçük `active_rows/active_cols` (ör. 2×2)
  ile başlamak çok daha az hataya açık.

## Sık görülen block design hataları (checklist)

- "Clock ... is not connected" (Validate Design) → paketlerken clk portu Associate Clocks ile
  işaretlenmemiş.
- PE board'da hep sıfır/donuk → `rst_n` polaritesi ters bağlanmış; waveform yerine ILA ile
  `rst_n` seviyesine bak.
- Reset path'te "unconstrained"/CDC uyarısı → `proc_sys_reset` kullanmadan PS reset'ini
  doğrudan PL'e çekince çıkar (UG906 `report_cdc` bunu da raporlar).
- 8×8'te port bit-width mismatch → flatten edilmiş geniş bus'u "Make External" yaparken
  genişliği elle doğrulamamak.

## Kaynaklar

- [AMD Processor System Reset Product Guide — PG080](https://docs.amd.com/r/en-US/pg080-proc-sys-reset)
- [AMD IP Integrator Tutorial — UG995](https://docs.amd.com/r/2024.1-English/ug995-vivado-ip-subsystems-tutorial/Step-2-Creating-an-IP-Integrator-Design)
- [AMD IP Subsystems — UG994](https://docs.amd.com/r/en-US/ug994-vivado-ip-subsystems/Common-Internal-Bus-Interfaces)
- [Zynq-7000 TRM — PS-PL clock/reset, UG585](https://docs.amd.com/v/u/en-US/ug585-Zynq-7000-TRM)
- [AMD Report Clock Domain Crossings — UG906](https://docs.amd.com/r/2023.1-English/ug906-vivado-design-analysis/Report-Clock-Domain-Crossings)

Not: [[Roadmap]] §7.3'teki DMA geliştirme sırası ve `vivado/check_synth.tcl`'in bugünkü
kapsamı (yalnız out-of-context synthesis, PS/IPI yok) göz önüne alınırsa, tam board bring-up
planlanandan erken bir adım — plan sırası madde 4-6'ya (banked feeder, AXI wrapper) girmeden
board'da PE/array denemek istersen yukarıdaki (A) yolu en düşük risklisi.
