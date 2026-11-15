---
title: ADR-012 Çalışma Zamanında Ağırlık Yükleme
created: 2026-11-15
modified: 2026-11-15
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, rtl, axi-lite, weight-load]
---

# ADR-012: Çalışma Zamanında Ağırlık Yükleme

## Durum
Kabul edildi — 2026-11-15 (Emin). Öneri 2026-11-14'te faz6 seam kontratında (§3) yazıldı ve
`faz6-shell` dalında uygulandı; bu ADR onu kayda geçiriyor.

## Bağlam
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] ağırlıkların 8 BRAM bankasına nasıl yerleştiğini
tanımlıyor ve `weight_feeder`'a bir yazma portu (`wr_en`, `wr_bank`, `wr_addr`, `wr_data`)
bırakıyordu; bu portu PS'ten kimin, hangi yoldan süreceği açıktı. faz5 sonunda port yalnız
testbench'ten sürülebiliyordu: PS'ten ağırlığa giden yol yoktu, yani bitstream'e gömülü olmayan
hiçbir model kartta çalıştırılamazdı. [[Roadmap]] bunu Aşama 3 (RFF) önkoşulu sayıyordu;
[[ADR-019 Geometry Envelope ve Model Geometry Kararı|ADR-019]] Aşama 1'e çekti.

## Karar
**Ağırlıklar PS'ten AXI4-Lite üzerinden, bayt başına bir yazmayla yüklenir.** Register map v5
iki register ekler ([[ADR-015 Register Map ve Parametre Yükleme|ADR-015]], 2026-11-15 eki):

```
0x028 W_ADDR   RW  [12:0] ADDR, [18:16] BANK      reset 0   (shadow değil, doğrudan)
0x02C W_DATA   WO  [7:0] DATA; okuma 0 döner
```

- `W_DATA` yazımı `bank_mem[BANK][ADDR] = DATA` yapar, sonra `ADDR` bir artar (13 bit sarar,
  `BANK` değişmez). Bir bankayı yüklemek: bir `W_ADDR` yazması, ardından ardışık `W_DATA`
  yazmaları.
- **`BUSY` iken `W_DATA` yazımı yok sayılır:** bellek değişmez, `ADDR` artmaz, `ERROR[3]`
  (`ERR_CFG_WR_BUSY`) kalkar. Ağırlık yalnız pass yokken yüklenir.
- Banka içeriği ve adresleme ADR-011'deki gibidir: banka `r = oc mod 8`, adres
  `w_base + (oc div 8)·k_len + k`. Hangi baytın nereye gideceğini host'taki `model/netprog.py`
  üretir; RTL yalnız (banka, adres, bayt) üçlüsünü yazar.
- `accel_top`'un çıplak `w_wr_*` giriş portları kalır (birim testleri onları kullanıyor);
  register kaynaklı yazma içeride onlarla mux'lanır. AXIS kabukta (`accel_axis`) bu portlar 0'a
  bağlıdır, yani kartta tek yol AXI4-Lite'tır.

Kapasite: banka başına 8192 bayt, toplam 65.536 bayt. Dondurulmuş model
`v3_48_deep_pool_refine` banka başına 6.086 bayt, toplam **48.688 bayt** tutar; tek yüklemeyle
sığar, katman arası yeniden yükleme gerekmez. Kapasiteyi aşan bir model, pass'ler arasında
(`BUSY = 0` iken) aynı mekanizmayla yeniden yüklenerek çalıştırılabilir; bu yol denenmedi.

## Alternatifler
- **DMA üzerinden ağırlık akışı:** aynı `s_axis` kanalından ikinci bir akış modu ve içeride mux
  gerektirir; kazancı yalnız model başına bir kez ödenen yükleme süresidir. Elendi. Kartta
  yükleme süresi ölçülünce yeniden bakılır.
- **Yalnız bitstream'e gömülü ağırlık (BRAM init, ADR-011 preload):** her model değişikliği
  yeni bitstream demektir ve Aşama 3'ün "aynı donanım, farklı model" hedefiyle çelişir. Preload
  simülasyon ve birim testleri için kalıyor, tek yol olmaktan çıkıyor.
- **AXI BRAM Controller ile PS'ten doğrudan BRAM erişimi:** bankaların ikinci portunu PS'e
  açmak gerekir; `weight_feeder`'ın okuma zamanlamasına ve ADR-011'in banka yapısına dokunur.
  Elendi.

## Sonuçlar
- Tam v3 modeli **48.688 AXI4-Lite yazması** + 8 `W_ADDR` yazmasıyla yüklenir, model başına bir
  kez. Kart üstü süre **ölçülmedi**. ADR-015'in varsayımlarıyla (bare-metal ≈ 0,1 µs, PYNQ
  Python MMIO ≈ 1 µs yazma başına) kabaca 5 ms ile 50 ms arası beklenir; PYNQ tarafında gerçek
  sayı bundan belirgin kötü çıkabilir. Kademe 4/5'te ölçülecek.
- Simülasyonda maliyet görünür: Kademe 3 (PS7 VIP) tam v3 koşusunun 45 dakikasına ağırlık
  yüklemesi hâkim.
- **Geri okuma yok.** `W_DATA` yalnız yazılır; yüklenen ağırlığı PS'ten doğrulamanın yolu yok.
  Yanlış yükleme ancak yanlış çıktıyla görünür. Gerekirse okuma yolu ayrı bir karar.
- `BUSY` iken yazmanın reddi sayesinde koşan bir pass'in ağırlığı yarıda değişemez; sürücü
  yükleme sonrası `ERROR[3]`'e bakmalıdır.
- Doğrulama: `tb_axis_shell` (register üzerinden yükleme, `BUSY` iken ret), `tb_prog_e2e`
  (v3 iki görüntü + LeNet, ağırlıklar yalnız bu yoldan), Kademe 3 `k3/tb_k3_prog.sv`
  (PS7 VIP GP0 üzerinden aynı yazmalar, tam v3 PASS).
- Program biçiminde (kontrat §6) ağırlık yüklemesi ayrı bir işlem değildir; `W 028 ...` ve
  `W 02C ...` satırlarıdır. Testbench, Kademe 3 ve PYNQ sürücüsü aynı satırları yürütür.
