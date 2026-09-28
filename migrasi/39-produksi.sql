-- =====================================================================
--  PENCATATAN PREPARATION / PRODUKSI
--  Jalankan sekali di Supabase → SQL Editor. Aman dijalankan berulang.
--
--  Masalah yang diselesaikan:
--  Cold brew, simple syrup, saus, ayam marinasi dibuat dalam batch lalu
--  dipakai berhari-hari. Selama ini bahan bakunya baru terpotong saat
--  menunya terjual — padahal robusta sudah habis sejak diseduh.
--  Akibatnya live stock bahan baku selalu lebih tinggi dari kenyataan,
--  dan hasil prep yang masih ada di kulkas tidak pernah terhitung saat
--  opname akhir bulan.
--
--  Setelah ini:
--    prep dicatat   -> bahan baku berkurang, hasil prep bertambah
--    menu terjual   -> hasil prep berkurang lewat resep seperti biasa
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. RESEP PRODUKSI — cara membuat satu batch
--     Bahan hasilnya harus sudah terdaftar di master bahan, mis. COLD BREW.
-- ---------------------------------------------------------------------
create table if not exists resep_produksi (
  id               uuid primary key default gen_random_uuid(),
  bahan_hasil_id   uuid not null references bahan(id) on delete restrict,
  nama             text not null,               -- mis. "Cold Brew batch besar"
  hasil_qty        numeric not null check (hasil_qty > 0),
  umur_simpan_hari int,                          -- kosongkan kalau tidak cepat rusak
  divisi           divisi_t not null default 'BAR',
  catatan          text,                         -- cara membuat, suhu, lama rendam
  aktif            boolean not null default true,
  dibuat           timestamptz not null default now()
);

create table if not exists resep_produksi_bahan (
  resep_id uuid not null references resep_produksi(id) on delete cascade,
  bahan_id uuid not null references bahan(id) on delete restrict,
  qty      numeric not null check (qty > 0),
  primary key (resep_id, bahan_id)
);

create index if not exists idx_rp_hasil on resep_produksi (bahan_hasil_id) where aktif;


-- ---------------------------------------------------------------------
--  2. CATATAN PRODUKSI — tiap kali prep dibuat
-- ---------------------------------------------------------------------
create table if not exists produksi (
  id               uuid primary key default gen_random_uuid(),
  periode          text not null default to_char(current_date,'YYYY-MM'),
  tanggal          date not null default current_date,
  waktu            timestamptz not null default now(),
  resep_id         uuid references resep_produksi(id) on delete set null,
  bahan_hasil_id   uuid not null references bahan(id) on delete restrict,
  batch            numeric not null default 1 check (batch > 0),
  hasil_seharusnya numeric,                      -- hasil_qty resep dikali batch
  hasil_nyata      numeric not null check (hasil_nyata >= 0),
  kadaluarsa       date,
  catatan          text,
  oleh             uuid references karyawan(id),
  dibuat           timestamptz not null default now()
);

create index if not exists idx_produksi_periode on produksi (periode, tanggal desc);
create index if not exists idx_produksi_hasil   on produksi (bahan_hasil_id, tanggal desc);

-- Bahan baku yang benar-benar terpakai. Diisi otomatis dari resep,
-- tapi boleh disesuaikan kalau kenyataannya berbeda.
create table if not exists produksi_bahan (
  produksi_id uuid not null references produksi(id) on delete cascade,
  bahan_id    uuid not null references bahan(id) on delete restrict,
  qty         numeric not null check (qty >= 0),
  primary key (produksi_id, bahan_id)
);


-- ---------------------------------------------------------------------
--  3. HASIL PREP YANG TERBUANG — basi, tumpah, atau gagal
-- ---------------------------------------------------------------------
create table if not exists produksi_buang (
  id          uuid primary key default gen_random_uuid(),
  periode     text not null default to_char(current_date,'YYYY-MM'),
  tanggal     date not null default current_date,
  bahan_id    uuid not null references bahan(id) on delete restrict,
  qty         numeric not null check (qty > 0),
  alasan      text not null,                     -- Kedaluwarsa | Tumpah | Gagal | Lain-lain
  produksi_id uuid references produksi(id) on delete set null,
  catatan     text,
  oleh        uuid references karyawan(id),
  dibuat      timestamptz not null default now()
);

create index if not exists idx_buang_periode on produksi_buang (periode, tanggal desc);


-- ---------------------------------------------------------------------
--  4. ISI OTOMATIS saat produksi dicatat
-- ---------------------------------------------------------------------
create or replace function produksi_isi_otomatis() returns trigger
language plpgsql security definer set search_path = public as $$
declare r resep_produksi%rowtype;
begin
  -- Kalau aplikasi lupa mengirim "oleh", isi sendiri. Tanpa ini barisnya
  -- ditolak aturan akses dan simpanannya gagal diam-diam.
  if new.oleh is null then new.oleh := id_saya(); end if;

  if new.resep_id is null then return new; end if;
  select * into r from resep_produksi where id = new.resep_id;
  if r.id is null then return new; end if;

  if new.hasil_seharusnya is null then
    new.hasil_seharusnya := r.hasil_qty * new.batch;
  end if;
  if new.kadaluarsa is null and r.umur_simpan_hari is not null then
    new.kadaluarsa := new.tanggal + r.umur_simpan_hari;
  end if;
  return new;
end $$;

drop trigger if exists trg_produksi_isi on produksi;
create trigger trg_produksi_isi before insert on produksi
for each row execute function produksi_isi_otomatis();


create or replace function produksi_isi_bahan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.resep_id is null then return null; end if;
  insert into produksi_bahan (produksi_id, bahan_id, qty)
  select new.id, rb.bahan_id, rb.qty * new.batch
  from resep_produksi_bahan rb
  where rb.resep_id = new.resep_id
  on conflict (produksi_id, bahan_id) do nothing;
  return null;
end $$;

drop trigger if exists trg_produksi_bahan on produksi;
create trigger trg_produksi_bahan after insert on produksi
for each row execute function produksi_isi_bahan();


create or replace function produksi_buang_isi() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.oleh is null then new.oleh := id_saya(); end if;
  return new;
end $$;

drop trigger if exists trg_produksi_buang_isi on produksi_buang;
create trigger trg_produksi_buang_isi before insert on produksi_buang
for each row execute function produksi_buang_isi();


-- ---------------------------------------------------------------------
--  5. DAMPAK KE STOK — dipakai aplikasi menghitung live stock
--     tambah = hasil prep yang jadi
--     kurang = bahan baku terpakai + hasil prep yang terbuang
-- ---------------------------------------------------------------------
drop function if exists produksi_dampak_stok(text);
create or replace function produksi_dampak_stok(p_periode text)
returns table (bahan_id uuid, nama text, satuan text,
               tambah numeric, kurang numeric, bersih numeric)
language sql stable set search_path = public as $$
  with gerak as (
    select p.bahan_hasil_id as bid, p.hasil_nyata as masuk, 0::numeric as keluar
    from produksi p where p.periode = p_periode
    union all
    select pb.bahan_id, 0, pb.qty
    from produksi_bahan pb
    join produksi p on p.id = pb.produksi_id
    where p.periode = p_periode
    union all
    select pbu.bahan_id, 0, pbu.qty
    from produksi_buang pbu where pbu.periode = p_periode
  )
  select g.bid, max(b.nama), max(b.satuan),
         sum(g.masuk), sum(g.keluar), sum(g.masuk) - sum(g.keluar)
  from gerak g join bahan b on b.id = g.bid
  group by g.bid
  order by 2
$$;

grant execute on function produksi_dampak_stok(text) to authenticated;


-- ---------------------------------------------------------------------
--  5b. HARGA PER SATUAN HASIL PREP
--      Cold brew tidak pernah dibeli, jadi harga_cadangan-nya nol.
--      Kalau dipakai apa adanya, satu jeriken cold brew yang basi
--      tercatat rugi Rp0 — padahal robusta di dalamnya sudah habis.
--      Jadi harganya dihitung dari biaya bahan baku bulan itu
--      dibagi total hasil nyatanya.
-- ---------------------------------------------------------------------
drop function if exists produksi_harga_satuan(text);
create or replace function produksi_harga_satuan(p_periode text)
returns table (bahan_id uuid, harga numeric)
language sql stable set search_path = public as $$
  with biaya as (
    select p.id, p.bahan_hasil_id as bid, max(p.hasil_nyata) as hasil,
           coalesce(sum(pb.qty * coalesce(b.harga_cadangan,0)), 0) as biaya
    from produksi p
    left join produksi_bahan pb on pb.produksi_id = p.id
    left join bahan b on b.id = pb.bahan_id
    where p.periode = p_periode
    group by p.id, p.bahan_hasil_id
  )
  select bid, round(coalesce(sum(biaya) / nullif(sum(hasil), 0), 0), 4)
  from biaya group by bid
$$;

grant execute on function produksi_harga_satuan(text) to authenticated;


-- ---------------------------------------------------------------------
--  6. DAFTAR PRODUKSI dengan selisih hasil dan biayanya
-- ---------------------------------------------------------------------
drop function if exists produksi_daftar(date, date, text);
create or replace function produksi_daftar(
  p_dari   date default current_date - 30,
  p_sampai date default current_date,
  p_divisi text default null
)
returns table (
  id uuid, tanggal date, waktu timestamptz,
  hasil text, satuan text, divisi text, resep text,
  batch numeric, hasil_seharusnya numeric, hasil_nyata numeric,
  selisih numeric, selisih_persen numeric,
  kadaluarsa date, sisa_hari int,
  biaya_bahan numeric, biaya_per_satuan numeric,
  oleh text, catatan text, jumlah_bahan int
)
language sql stable set search_path = public as $$
  select p.id, p.tanggal, p.waktu,
         b.nama, b.satuan, b.divisi::text, rp.nama,
         p.batch, p.hasil_seharusnya, p.hasil_nyata,
         p.hasil_nyata - p.hasil_seharusnya,
         case when p.hasil_seharusnya > 0
              then round((p.hasil_nyata - p.hasil_seharusnya) / p.hasil_seharusnya * 100, 1)
              else null end,
         p.kadaluarsa,
         case when p.kadaluarsa is null then null
              else (p.kadaluarsa - current_date)::int end,
         bi.biaya,
         case when p.hasil_nyata > 0 then round(bi.biaya / p.hasil_nyata, 2) else null end,
         k.nama, p.catatan, bi.n
  from produksi p
  join bahan b on b.id = p.bahan_hasil_id
  left join resep_produksi rp on rp.id = p.resep_id
  left join karyawan k on k.id = p.oleh
  left join lateral (
    select coalesce(sum(pb.qty * coalesce(nullif(bb.harga_cadangan,0), 0)), 0) as biaya,
           count(*)::int as n
    from produksi_bahan pb join bahan bb on bb.id = pb.bahan_id
    where pb.produksi_id = p.id
  ) bi on true
  where p.tanggal between p_dari and p_sampai
    and (p_divisi is null or b.divisi::text = p_divisi)
  order by p.waktu desc
$$;

grant execute on function produksi_daftar(date, date, text) to authenticated;


-- Rincian bahan satu catatan produksi
drop function if exists produksi_bahan_rinci(uuid);
create or replace function produksi_bahan_rinci(p_produksi_id uuid)
returns table (
  bahan_id uuid, bahan text, satuan text,
  qty numeric, qty_resep numeric, selisih numeric,
  harga numeric, biaya numeric
)
language sql stable set search_path = public as $$
  select pb.bahan_id, b.nama, b.satuan,
         pb.qty,
         rb.qty * p.batch,
         pb.qty - coalesce(rb.qty * p.batch, pb.qty),
         coalesce(nullif(b.harga_cadangan,0), 0),
         pb.qty * coalesce(nullif(b.harga_cadangan,0), 0)
  from produksi_bahan pb
  join produksi p on p.id = pb.produksi_id
  join bahan b on b.id = pb.bahan_id
  left join resep_produksi_bahan rb
         on rb.resep_id = p.resep_id and rb.bahan_id = pb.bahan_id
  where pb.produksi_id = p_produksi_id
  order by b.nama
$$;

grant execute on function produksi_bahan_rinci(uuid) to authenticated;


-- ---------------------------------------------------------------------
--  7. PREP YANG MENDEKATI KEDALUWARSA
-- ---------------------------------------------------------------------
drop function if exists produksi_kadaluarsa(int);
create or replace function produksi_kadaluarsa(p_hari int default 2)
returns table (
  id uuid, hasil text, divisi text, tanggal date, kadaluarsa date,
  sisa_hari int, hasil_nyata numeric, satuan text, oleh text
)
language sql stable set search_path = public as $$
  select p.id, b.nama, b.divisi::text, p.tanggal, p.kadaluarsa,
         (p.kadaluarsa - current_date)::int,
         p.hasil_nyata, b.satuan, k.nama
  from produksi p
  join bahan b on b.id = p.bahan_hasil_id
  left join karyawan k on k.id = p.oleh
  where p.kadaluarsa is not null
    and p.kadaluarsa <= current_date + p_hari
    -- yang sudah dibuang penuh tidak perlu diperingatkan lagi
    and coalesce((select sum(x.qty) from produksi_buang x where x.produksi_id = p.id), 0)
        < p.hasil_nyata
  order by p.kadaluarsa
$$;

grant execute on function produksi_kadaluarsa(int) to authenticated;


-- ---------------------------------------------------------------------
--  8. RINGKASAN SEBULAN
-- ---------------------------------------------------------------------
drop function if exists produksi_ringkas(text);
create or replace function produksi_ringkas(p_periode text)
returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'periode', p_periode,
    'jumlah_produksi', (select count(*) from produksi where periode = p_periode),
    'jenis_prep',      (select count(distinct bahan_hasil_id) from produksi where periode = p_periode),
    'biaya_bahan',     coalesce((
        select sum(pb.qty * coalesce(nullif(b.harga_cadangan,0),0))
        from produksi_bahan pb
        join produksi p on p.id = pb.produksi_id
        join bahan b on b.id = pb.bahan_id
        where p.periode = p_periode), 0),
    'terbuang_nilai',  coalesce((
        select sum(pbu.qty * coalesce(nullif(hs.harga,0), b.harga_cadangan, 0))
        from produksi_buang pbu
        join bahan b on b.id = pbu.bahan_id
        left join produksi_harga_satuan(p_periode) hs on hs.bahan_id = pbu.bahan_id
        where pbu.periode = p_periode), 0),
    'terbuang_kejadian', (select count(*) from produksi_buang where periode = p_periode),
    'selisih_hasil_rata', (
        select round(avg((hasil_nyata - hasil_seharusnya) / nullif(hasil_seharusnya,0) * 100), 1)
        from produksi where periode = p_periode and hasil_seharusnya > 0)
  )
$$;

grant execute on function produksi_ringkas(text) to authenticated;


-- Hasil prep mana yang paling sering terbuang
drop function if exists produksi_buang_ringkas(text);
create or replace function produksi_buang_ringkas(p_periode text)
returns table (bahan text, satuan text, kejadian int, total_qty numeric,
               nilai numeric, alasan_terbanyak text)
language sql stable set search_path = public as $$
  select b.nama, b.satuan, count(*)::int, sum(pbu.qty),
         round(sum(pbu.qty * coalesce(nullif(hs.harga,0), b.harga_cadangan, 0))),
         mode() within group (order by pbu.alasan)
  from produksi_buang pbu
  join bahan b on b.id = pbu.bahan_id
  left join produksi_harga_satuan(p_periode) hs on hs.bahan_id = pbu.bahan_id
  where pbu.periode = p_periode
  group by b.nama, b.satuan
  order by 5 desc
$$;

grant execute on function produksi_buang_ringkas(text) to authenticated;


-- Resep produksi beserta bahannya, untuk mengisi form
drop function if exists resep_produksi_daftar(text);
create or replace function resep_produksi_daftar(p_divisi text default null)
returns table (
  id uuid, nama text, hasil text, satuan text, divisi text,
  hasil_qty numeric, umur_simpan_hari int, catatan text,
  jumlah_bahan int, biaya_batch numeric
)
language sql stable set search_path = public as $$
  select rp.id, rp.nama, b.nama, b.satuan, rp.divisi::text,
         rp.hasil_qty, rp.umur_simpan_hari, rp.catatan,
         bi.n, bi.biaya
  from resep_produksi rp
  join bahan b on b.id = rp.bahan_hasil_id
  left join lateral (
    select count(*)::int as n,
           coalesce(sum(rb.qty * coalesce(nullif(bb.harga_cadangan,0),0)), 0) as biaya
    from resep_produksi_bahan rb join bahan bb on bb.id = rb.bahan_id
    where rb.resep_id = rp.id
  ) bi on true
  where rp.aktif and (p_divisi is null or rp.divisi::text = p_divisi)
  order by rp.nama
$$;

grant execute on function resep_produksi_daftar(text) to authenticated;


-- ---------------------------------------------------------------------
--  9. ATURAN AKSES
--     Semua karyawan divisi terkait boleh mencatat produksi — kalau hanya
--     head yang boleh, catatannya tidak akan pernah lengkap.
--     Resep produksi hanya head dan owner yang menetapkan.
-- ---------------------------------------------------------------------
alter table resep_produksi       enable row level security;
alter table resep_produksi_bahan enable row level security;
alter table produksi             enable row level security;
alter table produksi_bahan       enable row level security;
alter table produksi_buang       enable row level security;

drop policy if exists "resep produksi: baca" on resep_produksi;
create policy "resep produksi: baca" on resep_produksi for select to authenticated using (true);
drop policy if exists "resep produksi: ubah" on resep_produksi;
create policy "resep produksi: ubah" on resep_produksi for all to authenticated
  using (peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'))
  with check (peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));

drop policy if exists "resep produksi bahan: baca" on resep_produksi_bahan;
create policy "resep produksi bahan: baca" on resep_produksi_bahan for select to authenticated using (true);
drop policy if exists "resep produksi bahan: ubah" on resep_produksi_bahan;
create policy "resep produksi bahan: ubah" on resep_produksi_bahan for all to authenticated
  using (peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'))
  with check (peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));

drop policy if exists "produksi: baca" on produksi;
create policy "produksi: baca" on produksi for select to authenticated using (true);
drop policy if exists "produksi: catat" on produksi;
create policy "produksi: catat" on produksi for insert to authenticated
  with check (oleh is null or oleh = id_saya()
              or peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));
-- Mengubah catatan sendiri hanya di hari yang sama, supaya riwayatnya jujur
drop policy if exists "produksi: ubah" on produksi;
create policy "produksi: ubah" on produksi for update to authenticated
  using ((oleh = id_saya() and tanggal = current_date)
         or peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'))
  with check ((oleh = id_saya() and tanggal = current_date)
              or peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));
-- Salah ketik boleh dihapus sendiri di hari yang sama. Melarangnya tidak ada
-- gunanya selama mengubah angkanya sendiri masih boleh, dan di kafe kecil
-- yang belum punya head, tidak ada orang lain yang bisa membereskan.
drop policy if exists "produksi: hapus" on produksi;
create policy "produksi: hapus" on produksi for delete to authenticated
  using ((oleh = id_saya() and tanggal = current_date)
         or peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));

drop policy if exists "produksi bahan: baca" on produksi_bahan;
create policy "produksi bahan: baca" on produksi_bahan for select to authenticated using (true);
drop policy if exists "produksi bahan: ubah" on produksi_bahan;
create policy "produksi bahan: ubah" on produksi_bahan for all to authenticated
  using (true) with check (true);

drop policy if exists "produksi buang: baca" on produksi_buang;
create policy "produksi buang: baca" on produksi_buang for select to authenticated using (true);
drop policy if exists "produksi buang: catat" on produksi_buang;
create policy "produksi buang: catat" on produksi_buang for insert to authenticated
  with check (oleh is null or oleh = id_saya()
              or peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));
drop policy if exists "produksi buang: hapus" on produksi_buang;
create policy "produksi buang: hapus" on produksi_buang for delete to authenticated
  using ((oleh = id_saya() and tanggal = current_date)
         or peran_saya() in ('OWNER','HEAD_BAR','HEAD_KITCHEN'));


notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select produksi_ringkas('2026-09');
-- select * from produksi_daftar(current_date - 30, current_date);
-- select * from produksi_kadaluarsa(2);
-- select * from produksi_dampak_stok('2026-09');
-- select * from resep_produksi_daftar();
--
-- Bahan hasil prep harus didaftarkan dulu di master bahan, mis:
--   insert into bahan (nama, satuan, divisi, masuk_hpp)
--   values ('COLD BREW', 'ML', 'BAR', true);
