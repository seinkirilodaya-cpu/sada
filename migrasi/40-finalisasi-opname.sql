-- =====================================================================
--  FINALISASI OPNAME AKHIR BULAN
--  Jalankan sekali di Supabase → SQL Editor. Aman dijalankan berulang.
--
--  Masalah yang diselesaikan: dulu ada kode (gantiPeriode di
--  kelola-coffee-shop.jsx) yang menyalin hasil opname akhir bulan jadi
--  stok awal bulan berikutnya, tapi sejak aplikasi pindah ke memuat data
--  langsung dari server tiap ganti bulan, kode itu tidak pernah dipanggil
--  lagi. Akibatnya stok awal bulan baru SELALU 0 untuk semua bahan,
--  bukan cuma saat opname bulan sebelumnya kebetulan belum lengkap.
--
--  Sekarang: ada langkah eksplisit "Finalisasi" di halaman SO opname
--  detail. Baru boleh ditekan kalau semua bahan aktif sudah diisi opname
--  akhir bulannya (termasuk yang hasilnya 0 -- dicek lewat ADA TIDAKNYA
--  baris opname, bukan nilainya, supaya 0 yang sungguhan tidak dikira
--  belum diisi). Begitu ditekan, hasilnya disalin jadi stok awal
--  (sesi 'awal') bulan berikutnya.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Catatan periode mana saja yang sudah difinalisasi
-- ---------------------------------------------------------------------
create table if not exists opname_finalisasi (
  periode           text primary key,
  difinalisasi_oleh uuid references karyawan(id),
  difinalisasi_pada timestamptz not null default now()
);

alter table opname_finalisasi enable row level security;

drop policy if exists "opname finalisasi: baca" on opname_finalisasi;
create policy "opname finalisasi: baca" on opname_finalisasi for select to authenticated using (true);
-- Sengaja TIDAK ada policy insert/update langsung -- satu-satunya jalan
-- menulis ke tabel ini adalah lewat fungsi finalisasi_opname() di bawah,
-- yang memeriksa dulu peran dan kelengkapan opname-nya.


-- ---------------------------------------------------------------------
--  2. Status kelengkapan + finalisasi satu periode
--     "lengkap" dihitung dari ADA TIDAKNYA baris opname sesi 'akhir'
--     untuk tiap bahan aktif -- bukan dari nilainya -- supaya bahan yang
--     stoknya sungguhan 0 tetap terhitung sudah dihitung.
-- ---------------------------------------------------------------------
drop function if exists opname_finalisasi_status(text);
create or replace function opname_finalisasi_status(p_periode text)
returns table (
  periode text,
  total_bahan_aktif int,
  sudah_terisi int,
  sisa int,
  lengkap boolean,
  sudah_final boolean,
  difinalisasi_pada timestamptz,
  difinalisasi_oleh text
)
language sql stable set search_path = public as $$
  with aktif as (
    select id from bahan where aktif is distinct from false
  ),
  isi as (
    select o.bahan_id from opname o
    where o.periode = p_periode and o.sesi = 'akhir' and o.qty is not null
  ),
  hitungan as (
    select (select count(*) from aktif) as total,
           (select count(*) from aktif a join isi i on i.bahan_id = a.id) as terisi
  )
  select p_periode,
         h.total::int,
         h.terisi::int,
         (h.total - h.terisi)::int,
         h.total = h.terisi,
         f.periode is not null,
         f.difinalisasi_pada,
         k.nama
  from hitungan h
  left join opname_finalisasi f on f.periode = p_periode
  left join karyawan k on k.id = f.difinalisasi_oleh
$$;

grant execute on function opname_finalisasi_status(text) to authenticated;


-- ---------------------------------------------------------------------
--  3. Tombol Finalisasi -- memeriksa ulang di server (jangan percaya
--     penuh ke tombol di client, datanya bisa saja sudah basi), lalu
--     menyalin opname akhir bulan jadi stok awal bulan berikutnya.
--     Boleh ditekan ulang (mis. ada koreksi setelah difinalisasi) --
--     menimpa stok awal bulan berikutnya dengan angka yang terbaru.
-- ---------------------------------------------------------------------
drop function if exists finalisasi_opname(text);
create or replace function finalisasi_opname(p_periode text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_status record;
  v_periode_depan text;
  v_jumlah int;
begin
  if peran_saya() not in ('OWNER', 'FINANCE', 'PURCHASING') then
    raise exception 'Cuma OWNER, FINANCE, atau PURCHASING yang boleh finalisasi opname.';
  end if;

  select * into v_status from opname_finalisasi_status(p_periode);
  if not v_status.lengkap then
    raise exception 'Masih ada % bahan aktif yang opname akhir bulannya belum diisi.', v_status.sisa;
  end if;

  v_periode_depan := to_char((p_periode || '-01')::date + interval '1 month', 'YYYY-MM');

  insert into opname (periode, sesi, bahan_id, qty)
  select v_periode_depan, 'awal', o.bahan_id, o.qty
  from opname o
  join bahan b on b.id = o.bahan_id
  where o.periode = p_periode and o.sesi = 'akhir' and o.qty is not null
    and b.aktif is distinct from false
  on conflict (periode, sesi, bahan_id) do update set qty = excluded.qty;

  get diagnostics v_jumlah = row_count;

  insert into opname_finalisasi (periode, difinalisasi_oleh)
  values (p_periode, id_saya())
  on conflict (periode) do update
    set difinalisasi_oleh = excluded.difinalisasi_oleh, difinalisasi_pada = now();

  return json_build_object(
    'periode', p_periode,
    'periode_berikutnya', v_periode_depan,
    'bahan_disalin', v_jumlah
  );
end $$;

grant execute on function finalisasi_opname(text) to authenticated;


notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select * from opname_finalisasi_status('2026-09');
-- select finalisasi_opname('2026-09');   -- gagal kalau belum lengkap
-- select * from opname_finalisasi;
