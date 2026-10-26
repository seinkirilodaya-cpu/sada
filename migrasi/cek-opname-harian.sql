-- =====================================================================
--  CUMA MELIHAT -- tidak mengubah apa pun.
--  Untuk memeriksa kasus "Opname harian tersimpan tapi hilang setelah
--  refresh (mulai 21 Okt 2026)". Jalankan di Supabase SADA → SQL Editor,
--  satu blok per Run, lalu kirim hasilnya.
-- =====================================================================

-- 1) Berapa baris opname harian Oktober, dan per tanggal?
--    Kalau totalnya di atas 1000 dan tanggal 21-25 ada barisnya, datanya AMAN
--    di database -- yang hilang cuma saat dimuat (batas 1000 baris per permintaan).
select tanggal, count(*) as baris
from opname_harian
where periode = '2026-10'
group by tanggal
order by tanggal;

select count(*) as total_baris_oktober
from opname_harian
where periode = '2026-10';

-- 2) Kalau tanggal 21-25 TIDAK ada di atas: apakah tersimpan di periode lain?
select periode, tanggal, count(*) as baris
from opname_harian
where tanggal between 21 and 25
group by periode, tanggal
order by periode, tanggal;

-- 3) Aturan akses (RLS) tabel ini: siapa boleh baca/tambah/ubah/hapus
select policyname, cmd, roles, qual as syarat_baca, with_check as syarat_tulis
from pg_policies
where schemaname = 'public' and tablename = 'opname_harian'
order by cmd, policyname;

-- 4) Kunci unik untuk upsert (harus ada: periode + tanggal + bahan_id)
select conname, pg_get_constraintdef(oid) as definisi
from pg_constraint
where conrelid = 'public.opname_harian'::regclass;
