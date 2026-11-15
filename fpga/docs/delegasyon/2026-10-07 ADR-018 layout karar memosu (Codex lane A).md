# Karar sorusu

Karar, `requant_array` çıkışının yazıldığı ve sonraki layer'ın `window_gen`/`line_buffer` ya da FC1 tarafından okunduğu on-chip intermediate activation buffer'ın fiziksel byte sırasıdır. Bu seçim `requant` write path'ini, Conv2 replay address generator'ını, FC1 weight export'unu ve ADR-006 `TKEEP=all-1` invariant'ını birlikte kilitler; extract'te verilen aynı elemanın `188` ve `250` adreslerine düşmesi farkın cosmetic olmadığını gösterir.

## Secenekler

| Kriter | Option 1 — dense HWC, padding yok | Option 2 — padded tile-major | Option 3 — tile-major store + dense gather |
|---|---|---|---|
| 1. Write side | Lane'ler byte olarak contiguous, fakat Conv1'de 6-byte payload word-aligned değildir. `p*6 mod 8 = 0,6,4,2`; direct 64-bit store için beat'lerin yarısı 1, yarısı 2 word update ister: single write port ile 1/2 cycle, iki write port ile 1 cycle. Alternatif packer: 4 beat × 6 B = 3 aligned write. | `addr_word=((tile*H+h)*W+w)`; sekiz lane tek aligned 64-bit word. Bir write port, 1 cycle/beat; inactive lane'ler zero yazılır. | Store tarafı Option 2 ile aynı: bir write port, 1 cycle/beat. Scatter yok; gather maliyeti read side'a taşınır. |
| 2. Read side / Conv2 | Bugünkü RTL ile doğrudan uyumlu: Pool1 `14*14*6=1176 B`, `ROW_BYTES=14*6=84`. `line_buffer` row sınırını beat ortasında geçmeyi zaten destekliyor. Minimal RTL change: yok. | Unchanged RTL bozulur: `TOTAL_BYTES=1176` olduğu için 1568-byte fiziksel frame'in ilk 1176 byte'ını yanlış `(row,col,ch)` olarak tüketip erken `frame_done` verir. Stage 1 minimal change: `C_LOGICAL=6`, `C_PHYS=8`, `ROW_BYTES_PHYS=14*8=112`, `TOTAL_BYTES_PHYS=1568`; read index `col*8+ci`, `ci<6`. | Adapter 196 padded word okur (`1568/8`) ve 147 dense beat (`1176/8`) üretir; mevcut `line_buffer`/`window_gen` değişmez. Adapter'ın strip/repack FIFO'su ve backpressure contract'ı yenidir. |
| 3. Mathematical K | `K=6*5*5=150`. Address stride ve loop bound aynı `C=6` ile gider. | `K` yine `150`, `8*25=200` değildir. `ci<6`; `tile=ci>>3`, `lane=ci[2:0]`; fiziksel stride 8 yalnız address içindir. `C_PHYS` ile `K_LEN` üretmek 50 fazla term ve weight over-read üretir. | Adapter dışarı dense 6-channel view verir; generator yine `K=150`. Adapter'ın padding'i data olarak emit etmemesi gerekir. |
| 4. FC1 / ADR-011 | Kabul edilmiş transform aynen: `reshape(120,16,5,5).permute(0,2,3,1).reshape(120,400)`. | Physical order `[tile][h][w][lane]`; transform `reshape(120,2,8,5,5).permute(0,1,3,4,2).reshape(120,400)`. ADR-016 one-liner yanlış olur. | Gather FC1'e dense HWC verirse kabul edilmiş ADR-016 transform aynen kalır. | 
| 5. Byte / BRAM | Tablodaki tüm tensor'lar toplamı `3072+4704+1176+1600+400+120+84+40=11196 B`. Exact ping-pong minimum `2*4704=9408 B` = budget'ın `%1.46`'sı. | Toplam `3072+6272+1568+1600+400+120+88+40=13160 B`; dense'e ek `1964 B`. Exact ping-pong `2*6272=12544 B` = `%1.94`; ADR'nin 2×8 KiB allocation'ı `16384/645120=%2.54`. | Activation storage Option 2 ile aynı. Adapter FIFO/register maliyeti RTL olmadığı için sayısal olarak doğrulanmadı. |
| 6. 64-bit / TKEEP | Her row değil: Pool1 row `14*6=84 B=10.5 beat`; FC2 frame `84 B=10.5 beat`. Pool1 frame toplamı tam beat olsa da row-crossing packer gerekir; FC2 son beat partial veya ayrıca 4-byte tail pad ister. Saf Option 1 ADR-006 invariant'ını kırar. | Her fiziksel spatial row `W*8` per tile ve her FC vector padded: tam 8-byte word. Input özel dense case de `32*3=96 B/row`. `TKEEP=all-1` korunur. | Physical buffer ve adapter'ın dış 64-bit frame'leri tam beat yapılabilir; FC2 fiziksel 88 B. Dense Conv2 view 1176 B tam frame'dir, fakat adapter row boundary'de repack yapar. |
| 7. RTL cost | Read path bugün hazır; write packer, active-mask compaction ve partial-tail policy gerekir. Dense random address `(h*W+w)*C+ci`; static geometry'de nested counter ile multiplier/divider gerekmez. Max byte address 4703, 13 bit. | Write address common case word counter `+1`. `ci/8` ve `ci%8` general divide/modulo değil, shift/bit-slice. Read path'e logical/physical ayrımı ve tile base gerekir; max byte address 6271, 13 bit, word address 783, 10 bit. | Option 2 writer + gather FSM + repack FIFO + iki address sequence. Downstream address generator basit kalır; toplam state/backpressure yüzeyi en büyüktür. |
| 8. Silent corruption | Writer inactive lane'leri sıkıştırmazsa veya reader stride 8 kullanırsa shape/byte count doğru görünüp channel/pixel'ler kayar. `T_LAYOUT_ADDR_001` round-trip ve layer-by-layer bit-exact test yakalar. | `C_PHYS=8` yanlışlıkla `K_LEN=200` yapılırsa output shape doğru, değerler yanlış olur; flag yoktur. Conv2 testinde padding'i nonzero sentinel yapıp tam 150 accepted K beat saymak yakalar. Yanlış FC1 permute'u one-hot FC1 test yakalar. | Gather bir padding byte emit eder, bir byte skip/duplicate eder veya tile base'i bir word kaydırırsa dense output aynı boyda fakat yanlıştır. Sentinel round-trip + randomized backpressure + FC1 one-hot test yakalar. |
| 9. Stage 2 | `pad!=0` ve yeni arbitrary-`C` conv layer'lar bugünkü dense generator ile en ucuzdur. Current LeNet FC K-split'te 64-bit word sekiz K lane sağlayabilir; FC3 `K=84` tail mask ister. | FC K-split ve aligned eight-lane fetch doğaldır; `pad!=0` logical coordinate kontrolüyle eklenir. Fakat input `C>8` olan yeni conv'da physical stream `[tile][H][W][8]` sırası mevcut K-row ring'e uymaz; full-buffer gather veya line-buffer rewrite gerekir. | FC K-split physical word'leri doğrudan kullanabilir; dense mode mevcut `pad` path'ini ve arbitrary-`C` layer'ları korur. Yeni mode/config ve verification maliyeti vardır, rewrite riski adapter içinde sınırlandırılır. |

Not: `1 RAMB36 = 36*1024/8 = 4608 B`; iki bağımsız buffer'ın her biri hem 4704 B hem 6272 B için bir RAMB36'ı aşar. 64-bit contiguous realization'da her iki seçenek de en az 2 block/buffer, toplam 4 RAMB36 allocation ister. Buffer RTL'i ve BRAM width/depth configuration'ı mevcut olmadığı için actual post-synthesis BRAM count ölçüm değildir; yukarıdaki yüzde capacity hesabıdır.

## Secenek 1 — dense HWC, no channel padding

### Artilar

- `line_buffer.sv:37,40,72` mevcut contract'ı tam uygular: `ROW_BYTES=IN_W*C_IN`, `TOTAL_BYTES=IN_H*ROW_BYTES`, read `col*C_IN+ch`.
- `window_ref.py` tam `H*W*C` frame ve dense HWC index bekler; model değişmez.
- Conv2 replay `1176 B`; `line_buffer` write serialization tam 1176 byte sürer. Pool1'in 84-byte row'u için row-crossing desteği kodda ve comment'te zaten vardır.
- FC1 için ADR-016'da kabul edilen HWC weight transform korunur; future arbitrary logical `C` için fiziksel plane problemi yoktur.
- Full LeNet tensor toplamı Option 2'den `13160-11196=1964 B` küçüktür.

### Eksiler

- Conv1 her output position'da 6 valid byte üretir. Sekiz lane'i doğrudan yazmak mümkün değildir; 6-byte compaction/packer gerekir.
- Direct aligned update'te başlangıç offset'leri `0,6,4,2`; iki offset word crossing yapar. Single-port direct implementation beat başına worst-case 2 cycle'dır.
- Pool1 row 84 B olduğu için row-local 64-bit transfer yoktur. Mevcut `line_buffer` bunu serialize eder, fakat başka row-based consumer aynı özelliği yeniden uygulamalıdır.
- FC2 84 B ile ADR-006 `TKEEP=all-1` invariant'ını kırar. Tail pad eklemek Option 1'i tanım olarak değiştirir; eklenmezse functional `TKEEP` gerekir.
- En tehlikeli hata active mask'i ignore edip 8-byte stride kullanmaktır: buffer allocation ve output shape doğru kalabilir, değerler sessizce kayar.

## Secenek 2 — padded tile-major

### Artilar

- `requant_array` beat'i fiziksel word ile birebirdir: lane `r` → `addr_base+r`; mask dışı lane zero. Bir aligned 64-bit write, bir port, bir cycle.
- Conv1 ve Pool1 dahil her physical row/tile plane 8-byte multiple'dır; FC2 `84→88 B`. ADR-006 invariant'ı istisnasız korunur.
- Stage 1 Conv2 input'u tek channel tile'dır. Gerekli RTL ayrımı küçüktür: logical 6, physical stride 8; `K` loop'u 150'de kalır.
- Address generator'ın common write case'i word counter'dır. `/8` ve `%8` shift/bit-slice'tır; general divider gerekmez.
- Exact ping-pong yalnız `12544 B`; 630 KiB budget'ın `%1.94`'ü. ADR'nin 16 KiB allocation'ı `%2.54`'tür.
- FC K-split için her physical word sekiz K lane verir; FC2'nin son dört padded lane'i explicit mask ile güvenli şekilde sıfırlanabilir.

### Eksiler

- ADR-018 satır 105-107'deki “`window generator` zaten ayırıyor” iddiası mevcut RTL için doğru değildir. `line_buffer` tek `C_IN` kullanır; unchanged Conv2 kesin bozulur.
- Conv2 ingest `1176→1568 B`: mevcut byte-serialized writer 392 ek byte/cycle işler. Bu performance ölçümü değil, loop count farkıdır.
- FC1'de ADR-016 transform'u kullanılamaz. Yeni sıra açıkça `[out][tile][h][w][lane]` olmalıdır.
- `C>8` input'lu future conv layer'da `[tile][H][W][8]` physical stream, mevcut row-ring'e bütün channel'ları aynı zamanda getirmez. K-streaming'i korumak için full-buffer gather veya line-buffer redesign gerekir.
- `C_LOGICAL` ve `C_PHYS` aynı değişkenle temsil edilirse failure shape'i veya byte count'u bozmak zorunda değildir; bit-exact layer test olmadan kolay kaçırılır.

## Secenek 3 — tile-major store + dense gather

### Artilar

- Write side Option 2 kadar doğrudur ve basittir: aligned one-word store, constant all-1 physical byte enable.
- Mevcut `line_buffer`, `window_gen`, `window_ref.py` ve kabul edilmiş FC1 HWC transform'u dense interface arkasında korunur.
- Physical layout bilgisi tek adapter'da toplanır. Future `C>8` layer için adapter `[pixel][tile][lane]` read schedule üreterek downstream'i değiştirmeden genişleyebilir.
- ADR-006 physical storage invariant'ı korunur; Conv2 dense adapter output'u da `1176/8=147` full beat'tir.

### Eksiler

- Stage 1'e yeni bir stateful block ekler: padding strip, 64-bit repack, tile-plane gather, FIFO ve backpressure. Bit-exact correctness hedefinde verification surface en büyüktür.
- Conv2 için 196 physical read'den 147 dense beat üretir; Option 2'nin doğrudan read'ine göre byte taşımayı azaltmaz, yalnız format boundary'sini taşır.
- FC1 gather, Pool2 için tile0 word `p` ile tile1 word `25+p` sırasını interleave etmelidir. Bir tile-base off-by-one bütün 400-vector'u doğru boyda yanlış yapar.
- Adapter logic/FF/LUT/FIFO için RTL veya synthesis sonucu yoktur; BRAM dışı maliyet sayısallaştırılamaz.
- K-split physical order'ı doğrudan kullanacaksa adapter bypass/mode gerekir; tek dense-only contract ileride yeniden değiştirilir.

## Capraz etkiler

- **FC1 export:** Option 1 ve dense-presenting Option 3 için ADR-016 satır 130 geçerlidir. Option 2 için Kişi A şu exact transform'u kullanmalıdır: `w_fc1.reshape(120,2,8,5,5).permute(0,1,3,4,2).reshape(120,400)`. Pool2 `C=16` olduğu için padded K yoktur; physical ve mathematical uzunluk ikisi de 400'dür.
- **Conv weight export:** Üç option da ADR-011 “conv weights için no permutation” promise'ını koruyabilir ve korumalıdır. Şart, generator'ın logical order'ı `k=ci*25+kh*5+kw` tutmasıdır. Physical layout'u gerekçe gösterip `k=(kh*5+kw)*C+ci` yapmak promise'ı bozar; storage layout ile reduction order aynı şey değildir.
- **Conv2 replay:** Option 1 mevcut 1176-byte dense stream'dir. Option 2 doğrudan 1568-byte physical stream alır ama `ci<6` okur. Option 3 buffer'dan 1568 byte okuyup `line_buffer` önünde 1176 byte dense stream üretir. Her üçünde engine'e accepted activation beat sayısı output tile başına tam 150 olmalıdır.
- **`window_gen` / `line_buffer`:** `window_gen.sv:52` bugün `K_LEN=C_IN*K_H*K_W`; bu logical kalmalıdır. `line_buffer.sv:37,40,72` bugün aynı `C_IN`'ı physical row size ve logical bound için kullanır; Option 2 bunu iki parametreye ayırmadan uygulanamaz.
- **DMA input frame:** `32*32*3=3072 B=384 beat`, dense HWC ve padding yok; üç option için de değişmez. Option 2/3 padding yalnız PL içi intermediate buffer'da başlar. Input row `32*3=96 B`, zaten 8-byte multiple'dır.
- **Acceptance set:** `T_LAYOUT_ADDR_001` coordinate-coded round-trip (`188`/`250` checkpoint dahil), `T_CONV2_REPLAY_001` nonzero padding sentinel + 150-beat assertion, `T_FC1_ORDER_001` one-hot weight/activation, `T_AXI_ROW_001` row-crossing + final `TKEEP`, `T_NET_BITEXACT_001` her layer çıkışında golden compare. Sadece final argmax testi yeterli değildir.

## ONERI

**Option 2 — padded tile-major seçilsin.** Fixed LeNet-5 Stage 1 için bir format adapter eklemeden `requant_array` beat'ini tek aligned write'a çevirir, bütün intermediate frame/row'ları 8-byte boundary'de tutar ve ADR-006 `TKEEP=all-1` invariant'ını korur; 16 KiB rounded ping-pong yalnız 630 KiB budget'ın `%2.54`'üdür. Bedeli açıktır: mevcut `line_buffer` contract'ı değişecek, Conv2 392 padding byte işleyecek, FC1 export transform'u ADR-016'dakinden farklı olacak ve future `C>8` convolution input için full-buffer gather olmadan mevcut row-ring genellenemeyecektir. Bu bedeller, Option 1'in packer + partial-beat ambiguity'sinden ve Option 3'ün yeni backpressure-bearing adapter'ından Stage 1'de daha küçük ve daha kolay bit-exact test edilir.

Bunu seçerse yapılacaklar:

1. `line_buffer`/`window_gen` interface'ine ayrı `C_LOGICAL` ve `C_PHYS_STRIDE` ekle; Conv1 input için `3/3`, Conv2 input için `6/8` kullan. `K_LEN` yalnız `C_LOGICAL` ile hesaplansın.
2. Intermediate writer address'ini `(((c_out>>3)*H+h)*W+w)*8+(c_out&7)` olarak kilitle; inactive lane'leri zero yaz ve one-word/one-cycle assertion ekle.
3. `window_ref.py`ye ayrı physical tile-major buffer model + logical window stream ekle; padding byte'larını nonzero sentinel ile test ederek engine'e yine tam `K=150` beat gittiğini kanıtla.
4. Kişi A FC1 export'unu `reshape(120,2,8,5,5).permute(0,1,3,4,2).reshape(120,400)` yapacak; `.coe` için one-hot/order regression ekle. Conv weight export'una dokunma.
5. ADR-016 ve ADR-018'i bu kararla güncelle; `188/250` worked example'ı normative test vector yap ve future `C>8` conv için gather/redesign maddesini Stage 2 blocker olarak yaz.

## Bu karari gecersiz kilacak sey

Post-synthesis ya da XSim entegrasyon kanıtı, iki-parametreli Option 2 read path'inin BRAM inference/timing'i bozduğunu veya tile-major FC1/export yolunun bit-exact regression'da kalıcı hata yüzeyi yarattığını; buna karşılık dense compaction packer'ın full-rate, `TKEEP=all-1` ve tüm layer'larda tek contract ile daha az RTL/state kullanarak geçtiğini gösterirse recommendation Option 1'in **8-byte tensor-tail padded** varyantına döner. Ayrıca Stage 1 scope'una input `C>8` olan yeni bir convolution eklenirse, Option 2'nin row-ring avantajı biter; Option 3 yeniden değerlendirilmelidir.

## Dogrulanmamis varsayimlar

- İstenen `C:\codex-ctx\b19-b20-layout.txt` dosyası workspace'te yoktu ve `C:\` altında adla aramada bulunamadı. Bu nedenle extract'in `188`/`250` sonucu user prompt'undan alındı; elemanın coordinate'i ve B18/B19/B20/B36'daki diğer worked index'ler doğrulanamadı.
- Intermediate activation buffer RTL'i, pooling RTL'i, FC activation feeder ve layer sequencer bu dosya setinde yoktu. Bu yüzden actual BRAM primitive count, port mode, byte-write-enable availability, pooling read order ve measured cycle count verilmedi.
- BRAM yüzdeleri yalnız capacity hesabıdır: `140*36*1024/8=645120 B`. Vivado packing/inference sonucu değildir.
- Option 1 write cycle sayısı aligned 64-bit word memory + byte enables varsayımıyla architectural count'tur; farklı bank organization sonucu değiştirebilir. Packer'ın timing/resource ölçümü yoktur.
- Option 3 adapter'ın FIFO depth'i, combinational ready path'i ve sustained throughput'u tasarlanmadı; resource/cycle iddiası yapılmadı.
- Pooling output'un da seçilen physical layout ile yazılacağı varsayıldı. Pooling block farklı bir native order üretiyorsa recommendation yeniden cost edilmelidir.
- FC1 `C=16` olduğu için Option 2 transform'unda padded channel yoktur. Future non-multiple-of-8 FC input'ta weights'in padded K columns ile nasıl zero-extended edileceği ayrıca contract edilmelidir.
- `pad!=0` için `window_gen` coordinate check'i mevcut olsa da ADR-018'in söylediği DMA/border cycle contract ve verification vectors hâlâ yoktur; hiçbir option bunu tek başına kapatmaz.
