-- =====================================================================
--  CUMA MENGAMBIL/MELIHAT — tidak mengubah apa pun.
--  Mencari menu yang resepnya masih memakai bahan MENTAH secara langsung,
--  padahal bahan itu sudah punya resep produksi (mis. robusta+air -> cold
--  brew). Kalau menu itu SEHARUSNYA memakai hasil prepnya, robusta akan
--  terpotong DUA KALI: sekali lewat halaman Produksi, sekali lagi lewat
--  resep menu. Lihat migrasi/39-produksi.sql bagian "SAMBUNGAN KE STOK".
--
--  Tempel hasilnya ke Claude -- JANGAN diubah sendiri dari sini, resepnya
--  cuma boleh diedit lewat halaman Resep menu di aplikasi.
-- =====================================================================

select
  m.nama            as menu,
  b.nama            as bahan_mentah_dipakai_langsung_di_resep_menu,
  r.gramasi,
  bh.nama           as bahan_hasil_prep_yang_seharusnya_dipakai,
  rp.nama           as nama_resep_produksinya
from resep r
join bahan b               on b.id = r.bahan_id
join resep_produksi_bahan rpb on rpb.bahan_id = r.bahan_id
join resep_produksi rp     on rp.id = rpb.resep_id and rp.aktif
join bahan bh               on bh.id = rp.bahan_hasil_id
join menu m                 on m.id = r.menu_id
order by m.nama, b.nama;
