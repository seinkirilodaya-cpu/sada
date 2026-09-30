-- =====================================================================
--  ANALISIS KENAIKAN HARGA BAHAN
--  Jalankan sekali di Supabase → SQL Editor. Aman dijalankan berulang.
--
--  Menjawab tiga pertanyaan:
--    1. Bahan apa yang harganya naik dibanding bulan lalu
--    2. Berapa rupiah dampaknya ke biaya bulan ini
--    3. Menu apa yang paling terdampak
--
--  Harga yang dipakai = nilai belanja dibagi jumlah satuan stok yang masuk,
--  sama seperti yang dipakai aplikasi menghitung HPP.
-- =====================================================================


-- ---------------------------------------------------------------------
--  Harga rata-rata tiap bahan pada satu periode
-- ---------------------------------------------------------------------
drop function if exists harga_bahan_periode(text);
create or replace function harga_bahan_periode(p_periode text)
returns table (
  bahan_id uuid, bahan text, satuan text, divisi text,
  qty_beli numeric, nilai_belanja numeric, harga_rata numeric, kali_belanja int
)
language sql stable set search_path = public as $$
  select b.id, b.nama, b.satuan, b.divisi::text,
         sum(bl.qty), sum(bl.rupiah)::numeric,
         case when sum(bl.qty) > 0 then sum(bl.rupiah) / sum(bl.qty) else null end,
         count(*)::int
  from belanja bl
  join bahan b on b.id = bl.bahan_id
  where bl.periode = p_periode
  group by b.id, b.nama, b.satuan, b.divisi
  having sum(bl.qty) > 0
$$;

grant execute on function harga_bahan_periode(text) to authenticated;


-- ---------------------------------------------------------------------
--  Pemakaian bahan pada satu periode, dihitung dari resep dikali penjualan
-- ---------------------------------------------------------------------
drop function if exists pemakaian_bahan_periode(text);
create or replace function pemakaian_bahan_periode(p_periode text)
returns table (bahan_id uuid, terpakai numeric, jumlah_menu int)
language sql stable set search_path = public as $$
  select r.bahan_id, sum(r.gramasi * pj.qty), count(distinct r.menu_id)::int
  from resep r
  join penjualan pj on pj.menu_id = r.menu_id
  where pj.periode = p_periode
  group by r.bahan_id
$$;

grant execute on function pemakaian_bahan_periode(text) to authenticated;


-- ---------------------------------------------------------------------
--  Perbandingan harga: periode ini lawan periode sebelumnya
--
--  Kolom janggal menandai selisih yang lebih dari tiga kali lipat —
--  biasanya bukan harga yang benar-benar melonjak, tapi satuan belanja
--  yang berbeda antara dua bulan itu. Jangan dijumlahkan ke dampak total.
-- ---------------------------------------------------------------------
drop function if exists harga_naik(text, numeric);
create or replace function harga_naik(
  p_periode    text,
  p_min_persen numeric default 10
)
returns table (
  bahan_id uuid, bahan text, satuan text, divisi text,
  harga_lalu numeric, harga_kini numeric,
  selisih numeric, persen numeric,
  terpakai numeric, jumlah_menu int,
  dampak_rupiah numeric,
  janggal boolean
)
language sql stable set search_path = public as $$
  with lalu as (
    select * from harga_bahan_periode(
      to_char((p_periode || '-01')::date - interval '1 month', 'YYYY-MM'))
  ),
  kini as (select * from harga_bahan_periode(p_periode)),
  pakai as (select * from pemakaian_bahan_periode(p_periode))
  select k.bahan_id, k.bahan, k.satuan, k.divisi,
         round(l.harga_rata, 2), round(k.harga_rata, 2),
         round(k.harga_rata - l.harga_rata, 2),
         round((k.harga_rata - l.harga_rata) / l.harga_rata * 100, 1),
         coalesce(p.terpakai, 0),
         coalesce(p.jumlah_menu, 0),
         round((k.harga_rata - l.harga_rata) * coalesce(p.terpakai, 0), 0),
         (k.harga_rata / l.harga_rata > 3 or k.harga_rata / l.harga_rata < 1.0/3)
  from kini k
  join lalu l on l.bahan_id = k.bahan_id
  left join pakai p on p.bahan_id = k.bahan_id
  where l.harga_rata > 0
    and (k.harga_rata - l.harga_rata) / l.harga_rata * 100 >= p_min_persen
  order by round((k.harga_rata - l.harga_rata) * coalesce(p.terpakai, 0), 0) desc nulls last
$$;

grant execute on function harga_naik(text, numeric) to authenticated;


-- ---------------------------------------------------------------------
--  Ringkasan sebulan: berapa bahan naik, berapa turun, total dampaknya
--  Bahan bertanda janggal tidak ikut dijumlahkan.
-- ---------------------------------------------------------------------
drop function if exists harga_ringkas(text);
create or replace function harga_ringkas(p_periode text)
returns json
language sql stable set search_path = public as $$
  with n as (select * from harga_naik(p_periode, 0.01)),
       t as (select * from harga_naik(p_periode, -1000) where persen < 0)
  select json_build_object(
    'periode',        p_periode,
    'periode_lalu',   to_char((p_periode || '-01')::date - interval '1 month', 'YYYY-MM'),
    'bahan_naik',     (select count(*) from n where not janggal),
    'bahan_turun',    (select count(*) from t where not janggal),
    'dampak_naik',    (select coalesce(sum(dampak_rupiah), 0) from n where not janggal and dampak_rupiah > 0),
    'dampak_turun',   (select coalesce(sum(dampak_rupiah), 0) from t where not janggal and dampak_rupiah < 0),
    'dampak_bersih',  (select coalesce(sum(dampak_rupiah), 0)
                       from harga_naik(p_periode, -1000) where not janggal),
    'perlu_diperiksa',(select count(*) from harga_naik(p_periode, -1000) where janggal)
  )
$$;

grant execute on function harga_ringkas(text) to authenticated;


-- ---------------------------------------------------------------------
--  Menu yang paling terdampak oleh kenaikan satu bahan
-- ---------------------------------------------------------------------
drop function if exists menu_terdampak(uuid, text);
create or replace function menu_terdampak(p_bahan_id uuid, p_periode text)
returns table (
  menu_id uuid, menu text, kategori text, harga bigint,
  gramasi numeric, porsi numeric,
  tambahan_per_porsi numeric, tambahan_total numeric,
  persen_dari_harga numeric
)
language sql stable set search_path = public as $$
  with lalu as (
    select harga_rata from harga_bahan_periode(
      to_char((p_periode || '-01')::date - interval '1 month', 'YYYY-MM'))
    where bahan_id = p_bahan_id
  ),
  kini as (select harga_rata from harga_bahan_periode(p_periode) where bahan_id = p_bahan_id),
  selisih as (select (select harga_rata from kini) - (select harga_rata from lalu) as s)
  select m.id, m.nama, m.kategori, m.harga,
         r.gramasi,
         coalesce(sum(pj.qty), 0),
         round(r.gramasi * (select s from selisih), 2),
         round(r.gramasi * (select s from selisih) * coalesce(sum(pj.qty), 0), 0),
         case when m.harga > 0
              then round(r.gramasi * (select s from selisih) / m.harga * 100, 2)
              else null end
  from resep r
  join menu m on m.id = r.menu_id
  left join penjualan pj on pj.menu_id = m.id and pj.periode = p_periode
  where r.bahan_id = p_bahan_id and m.aktif
  group by m.id, m.nama, m.kategori, m.harga, r.gramasi
  order by 8 desc nulls last
$$;

grant execute on function menu_terdampak(uuid, text) to authenticated;


notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select harga_ringkas('2026-09');
-- select * from harga_naik('2026-09');           -- naik 10% atau lebih
-- select * from harga_naik('2026-09', 25);       -- naik 25% atau lebih
-- select * from menu_terdampak(
--   (select id from bahan where nama = 'FM DIAMOND (BAR)'), '2026-09');
