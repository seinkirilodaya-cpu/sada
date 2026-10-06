-- =====================================================================
--  MELIHAT PEMAKAIAN BAHAN (halaman Master bahan) -- khusus SADA
--  Jalankan sekali di Supabase SADA → SQL Editor. Aman dijalankan berulang.
--
--  Kenapa ada: halaman Master bahan memanggil bahan_ringkas_pakai(),
--  bahan_dipakai_menu(), dan bahan_jejak(), tapi ketiganya belum pernah
--  dibuat di database Sada (error PGRST202 / 404). Aslinya ada di migrasi
--  Seinkiri (23-bahan-dipakai.sql) dan tidak ikut dijalankan di Sada.
--
--  Bedanya dari versi Seinkiri: Sada punya tabel yang juga menahan
--  penghapusan bahan lewat foreign key "on delete restrict" --
--    resep_produksi (bahan hasil), resep_produksi_bahan, produksi (bahan
--    hasil), produksi_bahan, produksi_buang, dan dial_log.
--  Tanpa ikut dicek, tombol Hapus ditawarkan untuk bahan yang sebenarnya
--  ditolak database. Kolom lama dipertahankan persis; yang baru cuma
--  DITAMBAH, jadi tampilan lama tidak terganggu.
--
--  PENTING: kalau nanti ada tabel baru yang punya kolom ... references
--  bahan(id) on delete restrict, tambahkan juga ke tiga fungsi di bawah.
--
--  Pola akses sama dengan fungsi baca Sada lain (harga_naik, belanja_*):
--  security definer supaya hitungannya lengkap lintas periode dan lintas
--  RLS per-divisi (cuma angka hitungan, bukan isi baris), dicabut dari
--  anon, hanya untuk yang sudah login.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Menu yang memakai bahan ini (panel rincian)
-- ---------------------------------------------------------------------
drop function if exists bahan_dipakai_menu(uuid);
create or replace function bahan_dipakai_menu(p_bahan_id uuid)
returns table (
  menu_id   uuid,
  menu      text,
  kategori  text,
  gramasi   numeric,
  harga     bigint,
  aktif     boolean,
  terjual   numeric,
  biaya_per_porsi numeric
)
language sql stable security definer set search_path = public as $$
  select m.id, m.nama, m.kategori, r.gramasi, m.harga, m.aktif,
         coalesce((select sum(pj.qty) from penjualan pj
                   where pj.menu_id = m.id
                     and pj.periode = to_char(current_date,'YYYY-MM')), 0),
         r.gramasi * coalesce(nullif(b.harga_cadangan,0), 0)
  from resep r
  join menu m  on m.id = r.menu_id
  join bahan b on b.id = r.bahan_id
  where r.bahan_id = p_bahan_id
  order by m.aktif desc, m.nama
$$;

revoke all on function bahan_dipakai_menu(uuid) from public, anon;
grant execute on function bahan_dipakai_menu(uuid) to authenticated;


-- ---------------------------------------------------------------------
--  2. Seluruh jejak satu bahan -- termasuk yang menahan penghapusan
-- ---------------------------------------------------------------------
drop function if exists bahan_jejak(uuid);
create or replace function bahan_jejak(p_bahan_id uuid)
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'nama',          (select nama from bahan where id = p_bahan_id),
    'resep',         (select count(*) from resep r         where r.bahan_id = p_bahan_id),
    'belanja',       (select count(*) from belanja bl      where bl.bahan_id = p_bahan_id),
    'opname',        (select count(*) from opname o        where o.bahan_id = p_bahan_id),
    'opname_harian', (select count(*) from opname_harian oh where oh.bahan_id = p_bahan_id),
    'permintaan',    (select count(*) from permintaan p    where p.bahan_id = p_bahan_id),
    'nota',          (select count(*) from nota_baris nb   where nb.bahan_id = p_bahan_id),
    'resep_produksi',(select count(*) from resep_produksi rp where rp.bahan_hasil_id = p_bahan_id)
                   + (select count(*) from resep_produksi_bahan rpb where rpb.bahan_id = p_bahan_id),
    'produksi',      (select count(*) from produksi pr where pr.bahan_hasil_id = p_bahan_id)
                   + (select count(*) from produksi_bahan pb where pb.bahan_id = p_bahan_id),
    'produksi_buang',(select count(*) from produksi_buang pbu where pbu.bahan_id = p_bahan_id),
    'dial_in',       (select count(*) from dial_log dl     where dl.bahan_id = p_bahan_id),
    'boleh_hapus',   not exists (select 1 from resep r          where r.bahan_id = p_bahan_id)
                 and not exists (select 1 from belanja bl       where bl.bahan_id = p_bahan_id)
                 and not exists (select 1 from opname o         where o.bahan_id = p_bahan_id)
                 and not exists (select 1 from opname_harian oh where oh.bahan_id = p_bahan_id)
                 and not exists (select 1 from permintaan p     where p.bahan_id = p_bahan_id)
                 and not exists (select 1 from nota_baris nb    where nb.bahan_id = p_bahan_id)
                 and not exists (select 1 from resep_produksi rp where rp.bahan_hasil_id = p_bahan_id)
                 and not exists (select 1 from resep_produksi_bahan rpb where rpb.bahan_id = p_bahan_id)
                 and not exists (select 1 from produksi pr      where pr.bahan_hasil_id = p_bahan_id)
                 and not exists (select 1 from produksi_bahan pb where pb.bahan_id = p_bahan_id)
                 and not exists (select 1 from produksi_buang pbu where pbu.bahan_id = p_bahan_id)
                 and not exists (select 1 from dial_log dl      where dl.bahan_id = p_bahan_id)
  )
$$;

revoke all on function bahan_jejak(uuid) from public, anon;
grant execute on function bahan_jejak(uuid) to authenticated;


-- ---------------------------------------------------------------------
--  3. Ringkasan untuk SEMUA bahan sekaligus -- dipakai kolom "Dipakai",
--     penyaring "belum dipakai di menu mana pun", dan gerbang
--     Hapus/Nonaktifkan. Satu panggilan untuk semua baris.
--     Kolom lama sama persis; ada_produksi dan ada_dial ditambahkan.
-- ---------------------------------------------------------------------
drop function if exists bahan_ringkas_pakai();
create or replace function bahan_ringkas_pakai()
returns table (
  bahan_id uuid, menu_aktif int, menu_total int,
  ada_belanja int, ada_opname int, ada_permintaan int, ada_nota int,
  boleh_hapus boolean,
  ada_produksi int, ada_dial int
)
language sql stable security definer set search_path = public as $$
  select b.id,
    (select count(*)::int from resep r join menu m on m.id = r.menu_id
      where r.bahan_id = b.id and m.aktif),
    (select count(*)::int from resep r where r.bahan_id = b.id),
    (select count(*)::int from belanja bl    where bl.bahan_id = b.id),
    (select count(*)::int from opname o      where o.bahan_id = b.id),
    (select count(*)::int from permintaan p  where p.bahan_id = b.id),
    (select count(*)::int from nota_baris nb where nb.bahan_id = b.id),
    not exists (select 1 from resep r          where r.bahan_id = b.id)
    and not exists (select 1 from belanja bl   where bl.bahan_id = b.id)
    and not exists (select 1 from opname o     where o.bahan_id = b.id)
    and not exists (select 1 from opname_harian oh where oh.bahan_id = b.id)
    and not exists (select 1 from permintaan p where p.bahan_id = b.id)
    and not exists (select 1 from nota_baris nb where nb.bahan_id = b.id)
    and not exists (select 1 from resep_produksi rp where rp.bahan_hasil_id = b.id)
    and not exists (select 1 from resep_produksi_bahan rpb where rpb.bahan_id = b.id)
    and not exists (select 1 from produksi pr  where pr.bahan_hasil_id = b.id)
    and not exists (select 1 from produksi_bahan pb where pb.bahan_id = b.id)
    and not exists (select 1 from produksi_buang pbu where pbu.bahan_id = b.id)
    and not exists (select 1 from dial_log dl  where dl.bahan_id = b.id),
    (select count(*)::int from resep_produksi rp where rp.bahan_hasil_id = b.id)
      + (select count(*)::int from resep_produksi_bahan rpb where rpb.bahan_id = b.id)
      + (select count(*)::int from produksi pr where pr.bahan_hasil_id = b.id)
      + (select count(*)::int from produksi_bahan pb where pb.bahan_id = b.id)
      + (select count(*)::int from produksi_buang pbu where pbu.bahan_id = b.id),
    (select count(*)::int from dial_log dl where dl.bahan_id = b.id)
  from bahan b
$$;

revoke all on function bahan_ringkas_pakai() from public, anon;
grant execute on function bahan_ringkas_pakai() to authenticated;


notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select count(*) from bahan_ringkas_pakai();            -- = jumlah bahan
-- select * from bahan_ringkas_pakai() where not boleh_hapus limit 10;
-- select bahan_jejak((select id from bahan where upper(nama) = 'BEANS ARABICA'));
--
-- Bahan yang sama sekali tidak terpakai di mana pun -- kandidat dibersihkan:
-- select b.nama, b.divisi, b.satuan
-- from bahan b join bahan_ringkas_pakai() p on p.bahan_id = b.id
-- where p.boleh_hapus and b.aktif
-- order by b.nama;
