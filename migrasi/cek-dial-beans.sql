-- =====================================================================
--  CUMA MELIHAT -- tidak mengubah apa pun.
--  Jalankan di Supabase SADA (SQL Editor), tiap bagian satu-satu,
--  lalu tempel semua hasilnya ke Claude.
--  Tujuannya memastikan daftar_beans() benar sebelum dropdown beans
--  di halaman Dial in dipasang.
-- =====================================================================

-- 1) Apa yang dikembalikan daftar_beans() sekarang? (harus daftar beans saja)
select * from daftar_beans();

-- 2) Semua bahan yang kena filter lama (divisi BAR + satuan GRAM),
--    lengkap dengan harga -- supaya kelihatan mana yang BUKAN beans
--    dan apakah tiap beans sudah punya harga_cadangan (dipakai menghitung
--    nilai biji terbuang).
select id, nama, satuan, divisi, aktif, harga_cadangan
from bahan
where divisi = 'BAR' and satuan = 'GRAM'
order by nama;

-- 3) Calon beans menurut NAMA (kalau filter lama kurang tepat)
select id, nama, satuan, divisi, aktif, harga_cadangan
from bahan
where upper(nama) like '%BEAN%' or upper(nama) like '%ARABICA%'
   or upper(nama) like '%ROBUSTA%' or upper(nama) like '%KOPI%'
   or upper(nama) like '%COFFEE%' or upper(nama) like '%BLEND%'
order by nama;

-- 4) Definisi fungsi dial in yang sedang berjalan di database Sada
--    (untuk memastikan sama dengan migrasi Seinkiri 25/27/29: acuan dan
--    biji terbuang sudah dipisah per bahan_id)
select p.proname, pg_get_functiondef(p.oid) as definisi
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('daftar_beans', 'dial_acuan_bahan', 'dial_hari_ini',
                    'dial_riwayat', 'dial_terbuang', 'dial_terbuang_total');

-- 5) Aturan keunikan acuan (harus per bahan + metode + sajian)
select indexname, indexdef
from pg_indexes
where schemaname = 'public' and tablename = 'dial_acuan';
