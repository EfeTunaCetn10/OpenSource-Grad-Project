# Delegasyon kaydı — 2026-10-07 conv1 entegrasyonu

Bu klasör, conv1 entegrasyonunun paralel Codex lane'leriyle yürütülen kısmının ham
kaydıdır: hangi lane'e ne verildi, ne döndürdü. Kod değil, karar izi. ADR-018 ve ADR-011
bu dosyalardaki ölçümlere atıf yapıyor, o yüzden repo içinde tutuluyorlar.

Kurulum: `gpt-5.6-sol`, `model_reasoning_effort=high`, her lane kendi `git worktree`'sinde
(`C:/grad-wf`, `C:/grad-lc`, `C:/grad-win`), prompt stdin'den veriliyor — argüman olarak
verilince ilk satırda kesiliyor.

| Dosya | Ne |
| --- | --- |
| `2026-10-07 Conv1 entegrasyon seam kontrati.md` | Lane B ve C'ye **önceden** verilen bağlayıcı kontrat: modül adları, parametre listeleri, her port adı/genişliği, `error_flags` bit ataması. İki yarının ilk denemede birbirine oturmasının sebebi bu; lane'ler yalnız iç mantığı yazdı. |
| `2026-10-07 ADR-018 layout karar memosu (Codex lane A).md` | Ara aktivasyon buffer'ının fiziksel layout'u için üç seçeneğin dokuz kriterde artı/eksi karşılaştırması. Öneri padded tile-major; Emin bu seçeneği onayladı, karar ADR-018'e yazıldı. Memo kendi doğrulanmamış varsayımlarını da listeliyor — özellikle çalışma kitabı extract'inin o koşuda bulunamadığını açıkça kaydetmiş (kopyalama komutu parse hatası yüzünden hiç koşmamıştı). FC1 transform'unu yine de kitapla aynı bulması o boşluğu fiilen kapatıyor. |
| `2026-10-07 lane-b raporu.md` | `weight_feeder` + tb. 8/8 regression, 5 mutant / 5 yakalandı. `line_buffer`'ın kombinasyonel okuma bulgusunu da rapor etti — sonradan sentezde ölçülerek doğrulandı. |
| `2026-10-07 lane-c raporu.md` | `layer_ctrl` + tb. 8/8 regression, 5 mutant / 5 yakalandı. `window_gen`'in `ST_DONE`'unun terminal olduğunu bağımsız olarak tespit etti. |
| `2026-10-07 lane-a raporu.md` | Lane A'nın kapanış mesajı. |
| `2026-10-07 lane-*.txt` | Lane'lere verilen promptlar, olduğu gibi. |

## Eksik: timing lane raporu

`window_gen` + `line_buffer` timing reworkünü yazan lane (`2026-10-07 lane-timing
prompt.txt`) 60 dakikalık timeout'a takılıp **regression'a girmeden kesildi**, bu yüzden
kendi raporu yok. RTL'i worktree'de bırakmıştı; doğrulamayı ve ikinci turu
(`line_buffer` ring'inin banka başına ayrı diziye taşınması) Agâh yaptı. Ölçümler ADR-018'in
2026-10-07 ek maddesinde ve `systolic-array-8x8/README.md`'nin sentez bölümünde:
WNS −33,324 → +0,075 → +1,203 ns, post-route +0,920 ns setup / +0,050 ns hold.
