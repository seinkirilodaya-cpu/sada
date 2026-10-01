-- =====================================================================
--  ANALISIS KINERJA BELANJA
--  Jalankan sekali di Supabase → SQL Editor. Aman dijalankan berulang.
--
--  Menjawab empat pertanyaan:
--    1. Berapa lama dari karyawan minta sampai barang benar-benar datang
--    2. Berapa banyak yang tidak jadi dibeli, dan kenapa
--    3. Bahan apa yang sering datang kurang dari yang dibeli
--    4. Permintaan apa yang masih menggantung sekarang
-- =====================================================================


-- ---------------------------------------------------------------------
--  Riwayat satu permintaan dari awal sampai barangnya sampai
--  Waktu dihitung dari tabel nota, bukan dari kolom di permintaan,
--  supaya tetap bekerja meski kolom jejak waktu di permintaan berbeda.
-- ---------------------------------------------------------------------
drop function if exists belanja_perjalanan(date, date);
create or replace function belanja_perjalanan(
  p_dari   date default current_date - 30,
  p_sampai date default current_date
)
returns table (
  permintaan_id uuid, bahan text, divisi text,
  diajukan date, diminta_oleh text,
  masuk_daftar date, dicek date,
  hari_ke_daftar int, hari_daftar_ke_cek int, hari_total int,
  status text, tidak_dibeli boolean, alasan text,
  qty_minta numeric, qty_beli numeric, qty_datang numeric
)
language sql stable set search_path = public as $$
  select p.id, b.nama, b.divisi::text,
         p.tanggal, k.nama,
         n.tanggal,
         (n.waktu_cek at time zone 'Asia/Jakarta')::date,
         (n.tanggal - p.tanggal)::int,
         ((n.waktu_cek at time zone 'Asia/Jakarta')::date - n.tanggal)::int,
         ((n.waktu_cek at time zone 'Asia/Jakarta')::date - p.tanggal)::int,
         p.status, nb.tidak_dibeli, nb.alasan,
         nb.qty_minta, nb.qty_beli, nb.qty_datang
  from permintaan p
  join bahan b on b.id = p.bahan_id
  left join karyawan k on k.id = p.oleh
  left join nota_baris nb on nb.permintaan_id = p.id
  left join nota n on n.id = nb.nota_id
  where p.tanggal between p_dari and p_sampai
  order by p.tanggal desc, b.nama
$$;

grant execute on function belanja_perjalanan(date, date) to authenticated;


-- ---------------------------------------------------------------------
--  Ringkasan kinerja
-- ---------------------------------------------------------------------
drop function if exists belanja_ringkas(date, date);
create or replace function belanja_ringkas(
  p_dari   date default current_date - 30,
  p_sampai date default current_date
)
returns json
language sql stable set search_path = public as $$
  with j as (select * from belanja_perjalanan(p_dari, p_sampai))
  select json_build_object(
    'dari',   p_dari,
    'sampai', p_sampai,
    'jumlah_permintaan',   (select count(*) from j),
    'sudah_dibelanjakan',  (select count(*) from j where masuk_daftar is not null),
    'sudah_dicek',         (select count(*) from j where dicek is not null),
    'masih_menggantung',   (select count(*) from j where masuk_daftar is null
                                            and status in ('Baru','Disetujui')),
    'ditolak',             (select count(*) from j where status = 'Ditolak'),
    'tidak_jadi_dibeli',   (select count(*) from j where tidak_dibeli),
    'hari_ke_daftar',      (select round(avg(hari_ke_daftar), 1) from j where hari_ke_daftar is not null),
    'hari_daftar_ke_cek',  (select round(avg(hari_daftar_ke_cek), 1) from j where hari_daftar_ke_cek is not null),
    'hari_total',          (select round(avg(hari_total), 1) from j where hari_total is not null),
    'paling_lama_hari',    (select max(hari_total) from j),
    'datang_kurang',       (select count(*) from j
                            where qty_datang is not null and qty_beli is not null
                              and qty_datang < qty_beli),
    'datang_pas_persen',   (select case when count(*) filter (where qty_datang is not null) = 0 then null
                            else round(count(*) filter (where qty_datang >= qty_beli) * 100.0
                                     / count(*) filter (where qty_datang is not null), 1) end from j)
  )
$$;

grant execute on function belanja_ringkas(date, date) to authenticated;


-- ---------------------------------------------------------------------
--  Alasan bahan tidak jadi dibeli
-- ---------------------------------------------------------------------
drop function if exists belanja_alasan(date, date);
create or replace function belanja_alasan(
  p_dari   date default current_date - 30,
  p_sampai date default current_date
)
returns table (alasan text, jumlah int, bahan_terbanyak text, persen numeric)
language sql stable set search_path = public as $$
  with j as (select * from belanja_perjalanan(p_dari, p_sampai) where tidak_dibeli),
       t as (select count(*)::numeric as n from j)
  select coalesce(j.alasan, '(tanpa alasan)'),
         count(*)::int,
         mode() within group (order by j.bahan),
         round(count(*) * 100.0 / nullif((select n from t), 0), 1)
  from j
  group by coalesce(j.alasan, '(tanpa alasan)')
  order by 2 desc
$$;

grant execute on function belanja_alasan(date, date) to authenticated;


-- ---------------------------------------------------------------------
--  Bahan yang sering datang kurang dari yang dibeli
-- ---------------------------------------------------------------------
drop function if exists belanja_kurang(date, date);
create or replace function belanja_kurang(
  p_dari   date default current_date - 30,
  p_sampai date default current_date
)
returns table (
  bahan text, divisi text,
  kali_datang int, kali_kurang int, persen_kurang numeric,
  total_dibeli numeric, total_datang numeric, total_kurang numeric
)
language sql stable set search_path = public as $$
  select j.bahan, j.divisi,
         count(*) filter (where j.qty_datang is not null)::int,
         count(*) filter (where j.qty_datang < j.qty_beli)::int,
         round(count(*) filter (where j.qty_datang < j.qty_beli) * 100.0
               / nullif(count(*) filter (where j.qty_datang is not null), 0), 1),
         sum(j.qty_beli) filter (where j.qty_datang is not null),
         sum(j.qty_datang),
         sum(j.qty_beli - j.qty_datang) filter (where j.qty_datang < j.qty_beli)
  from belanja_perjalanan(p_dari, p_sampai) j
  where j.qty_datang is not null
  group by j.bahan, j.divisi
  having count(*) filter (where j.qty_datang < j.qty_beli) > 0
  order by 8 desc nulls last
$$;

grant execute on function belanja_kurang(date, date) to authenticated;


-- ---------------------------------------------------------------------
--  Permintaan yang masih menggantung sekarang
-- ---------------------------------------------------------------------
drop function if exists belanja_menggantung();
create or replace function belanja_menggantung()
returns table (
  permintaan_id uuid, bahan text, divisi text, status text,
  urgensi text, diajukan date, umur_hari int, diminta_oleh text
)
language sql stable set search_path = public as $$
  select p.id, b.nama, b.divisi::text, p.status,
         p.urgensi, p.tanggal, (current_date - p.tanggal)::int, k.nama
  from permintaan p
  join bahan b on b.id = p.bahan_id
  left join karyawan k on k.id = p.oleh
  where p.status in ('Baru','Disetujui')
    and not exists (select 1 from nota_baris nb where nb.permintaan_id = p.id)
  order by (current_date - p.tanggal) desc
$$;

grant execute on function belanja_menggantung() to authenticated;


notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select belanja_ringkas(date '2026-09-01', date '2026-09-30');
-- select * from belanja_alasan(date '2026-09-01', date '2026-09-30');
-- select * from belanja_kurang(date '2026-09-01', date '2026-09-30');
-- select * from belanja_menggantung();
