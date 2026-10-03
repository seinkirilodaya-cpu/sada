-- =====================================================================
--  ABSEN KEHADIRAN (foto selfie + lokasi GPS) -- khusus SADA
--  Jalankan sekali di Supabase SADA → SQL Editor. Aman dijalankan berulang.
--
--  Catatan nama: halaman "Cuti & izin" memakai tabel pengajuan_absen.
--  Itu pengajuan cuti/izin/sakit, BUKAN kehadiran -- jadi tabel di bawah
--  ini terpisah dan tidak bentrok.
--
--  Prinsip:
--   * Karyawan TIDAK menulis langsung ke tabel absen. Semua lewat fungsi
--     catat_absen(), supaya waktu, jarak, status, dan anomali dihitung di
--     SERVER -- bukan dipercayakan ke jam/angka kiriman HP.
--   * Foto di bucket privat, hanya Owner yang bisa melihat (signed URL).
--   * Jam shift dibaca dari pengaturan.shift bulan itu (yang diatur Owner di
--     halaman Jadwal shift). Jam bawaan di bawah cuma cadangan kalau kode
--     shift itu belum pernah diubah -- sama dengan SHIFT_AWAL di aplikasi.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. PENGATURAN ABSEN (satu baris saja, bukan per bulan)
--     Koordinat outlet SENGAJA kosong -- diisi Owner lewat halaman Absen.
-- ---------------------------------------------------------------------
create table if not exists pengaturan_absen (
  id                        boolean primary key default true check (id),
  lokasi_outlet_lat         numeric check (lokasi_outlet_lat between -90 and 90),
  lokasi_outlet_lng         numeric check (lokasi_outlet_lng between -180 and 180),
  radius_m                  int not null default 100 check (radius_m > 0),
  toleransi_terlambat_menit int not null default 10 check (toleransi_terlambat_menit >= 0),
  akurasi_gps_maks_m        int not null default 50 check (akurasi_gps_maks_m > 0),
  retensi_foto_hari         int not null default 7 check (retensi_foto_hari > 0),
  absen_pulang_wajib        boolean not null default true,
  blok_di_luar_radius       boolean not null default false
);

insert into pengaturan_absen (id) values (true) on conflict (id) do nothing;

alter table pengaturan_absen enable row level security;

drop policy if exists "pengaturan absen: baca" on pengaturan_absen;
create policy "pengaturan absen: baca" on pengaturan_absen for select to authenticated
  using (peran_saya() = 'OWNER');
drop policy if exists "pengaturan absen: ubah" on pengaturan_absen;
create policy "pengaturan absen: ubah" on pengaturan_absen for update to authenticated
  using (peran_saya() = 'OWNER') with check (peran_saya() = 'OWNER');


-- ---------------------------------------------------------------------
--  2. ABSEN -- satu baris per absen masuk / pulang
-- ---------------------------------------------------------------------
create table if not exists absen (
  id                  uuid primary key default gen_random_uuid(),
  karyawan_id         uuid not null references karyawan(id) on delete restrict,
  tanggal             date not null,                       -- tanggal SHIFT (WIB)
  jenis               text not null check (jenis in ('masuk','pulang')),
  waktu               timestamptz not null default now(),  -- diisi server
  lat                 numeric,
  lng                 numeric,
  akurasi_m           numeric,
  jarak_dari_outlet_m numeric,
  foto_path           text,
  foto_dihapus_pada   timestamptz,
  kode_shift          text,                                -- S1/MD/S2/... dari tabel jadwal
  status              text not null
                      check (status in ('tepat_waktu','terlambat','pulang_cepat','tanpa_jadwal')),
  selisih_menit       int,   -- masuk: menit setelah jam mulai; pulang: menit setelah jam selesai (minus = lebih awal)
  dinas_luar          boolean not null default false,
  keterangan_dinas    text,
  anomali             text[] not null default '{}',
  ditinjau_oleh       uuid references karyawan(id),
  ditinjau_pada       timestamptz,
  hasil_koreksi       boolean not null default false,
  ip                  text,
  device_id           text,
  user_agent          text,
  dibuat              timestamptz not null default now(),
  unique (karyawan_id, tanggal, jenis)
);

create index if not exists idx_absen_tanggal on absen (tanggal);
create index if not exists idx_absen_device on absen (device_id, tanggal) where device_id is not null;
create index if not exists idx_absen_anomali on absen (waktu)
  where cardinality(anomali) > 0 and ditinjau_pada is null;

alter table absen enable row level security;

-- Sengaja TIDAK ada policy insert/update/delete: hanya fungsi di bawah
-- (security definer) yang boleh menulis.
drop policy if exists "absen kehadiran: baca" on absen;
create policy "absen kehadiran: baca" on absen for select to authenticated
  using (karyawan_id = id_saya() or peran_saya() = 'OWNER');


-- ---------------------------------------------------------------------
--  3. KOREKSI ABSEN
-- ---------------------------------------------------------------------
create table if not exists absen_koreksi (
  id              uuid primary key default gen_random_uuid(),
  karyawan_id     uuid not null references karyawan(id) on delete restrict,
  tanggal         date not null,
  jenis           text not null check (jenis in ('masuk','pulang')),
  jam_diajukan    time not null,
  alasan          text not null check (length(btrim(alasan)) > 0),
  status          text not null default 'menunggu'
                  check (status in ('menunggu','disetujui','ditolak')),
  diputuskan_oleh uuid references karyawan(id),
  balasan         text,
  dibuat          timestamptz not null default now(),
  diputuskan_pada timestamptz
);

create index if not exists idx_absen_koreksi_status on absen_koreksi (status, dibuat desc);

alter table absen_koreksi enable row level security;

drop policy if exists "absen koreksi: baca" on absen_koreksi;
create policy "absen koreksi: baca" on absen_koreksi for select to authenticated
  using (karyawan_id = id_saya() or peran_saya() = 'OWNER');


-- ---------------------------------------------------------------------
--  4. BUKTI PERSETUJUAN (foto dan lokasi dipakai untuk absensi)
-- ---------------------------------------------------------------------
create table if not exists absen_persetujuan (
  id           uuid primary key default gen_random_uuid(),
  karyawan_id  uuid not null references karyawan(id) on delete cascade,
  versi        text not null,
  disetujui_pada timestamptz not null default now(),
  ip           text,
  user_agent   text,
  unique (karyawan_id, versi)
);

alter table absen_persetujuan enable row level security;

drop policy if exists "absen persetujuan: baca" on absen_persetujuan;
create policy "absen persetujuan: baca" on absen_persetujuan for select to authenticated
  using (karyawan_id = id_saya() or peran_saya() = 'OWNER');


-- ---------------------------------------------------------------------
--  5. FUNGSI BANTU (internal -- tidak dibuka ke aplikasi)
-- ---------------------------------------------------------------------

-- IP pemanggil, dibaca dari header permintaan (diisi server, bukan klien).
create or replace function absen_ip() returns text
language plpgsql stable set search_path = public as $$
declare v_hdr json;
begin
  begin
    v_hdr := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    return null;
  end;
  return nullif(btrim(split_part(
    coalesce(v_hdr->>'x-forwarded-for', v_hdr->>'cf-connecting-ip', ''), ',', 1)), '');
end $$;


-- Jam mulai & selesai satu kode shift pada bulan tanggal itu.
-- Baca pengaturan.shift -> kode -> jam ("09.30–16.30"); kalau belum pernah
-- diubah, pakai jam bawaan yang sama dengan SHIFT_AWAL di aplikasi.
-- Kode tanpa jam (OF/CT/IZ/SK, atau tak terbaca) -> tidak mengembalikan baris.
drop function if exists absen_jam_shift(text, date);
create or replace function absen_jam_shift(p_kode text, p_tanggal date)
returns table (mulai time, selesai time)
language plpgsql stable set search_path = public as $$
declare
  v_txt text;
  m text[];
begin
  if p_kode is null then return; end if;

  select (s.shift::jsonb) -> p_kode ->> 'jam' into v_txt
  from pengaturan s where s.periode = to_char(p_tanggal, 'YYYY-MM');

  if v_txt is null or btrim(v_txt) = '' then
    v_txt := case p_kode
      when 'S1' then '09.30–16.30'
      when 'MD' then '12.00–20.00'
      when 'S2' then '16.00–01.00'
    end;
  end if;
  if v_txt is null then return; end if;

  m := regexp_match(v_txt, '(\d{1,2})[.:](\d{2})\s*[–—-]\s*(\d{1,2})[.:](\d{2})');
  if m is null then return; end if;

  mulai   := make_time(m[1]::int, m[2]::int, 0);
  selesai := make_time(m[3]::int, m[4]::int, 0);
  return next;
end $$;


-- Tanggal SHIFT untuk "sekarang": sebelum jam 06.00, kalau kemarin ada absen
-- masuk yang belum ada pulangnya, berarti masih shift kemarin (mis. shift
-- 16.00-01.00 yang pulang lewat tengah malam).
create or replace function absen_tanggal_shift(p_karyawan uuid, p_lokal timestamp)
returns date
language sql stable set search_path = public as $$
  select case
    when p_lokal::time < time '06:00'
     and exists (select 1 from absen a where a.karyawan_id = p_karyawan
                  and a.tanggal = p_lokal::date - 1 and a.jenis = 'masuk')
     and not exists (select 1 from absen a where a.karyawan_id = p_karyawan
                  and a.tanggal = p_lokal::date - 1 and a.jenis = 'pulang')
    then p_lokal::date - 1
    else p_lokal::date
  end
$$;


-- Status & selisih menit terhadap jadwal shift hari itu.
--   masuk : terlambat kalau waktu > jam mulai + toleransi
--   pulang: pulang_cepat kalau waktu < jam selesai
-- Tidak ada jadwal kerja (kosong / libur / cuti / izin / sakit) -> tanpa_jadwal.
drop function if exists absen_hitung(uuid, date, text, timestamptz, int);
create or replace function absen_hitung(
  p_karyawan uuid, p_tanggal date, p_jenis text, p_waktu timestamptz, p_toleransi int
)
returns table (r_kode text, r_status text, r_selisih_menit int, r_jauh boolean, r_tanpa_jadwal boolean)
language plpgsql stable set search_path = public as $$
declare
  v_kode text;
  v_mulai time;
  v_selesai time;
  v_ts_mulai timestamptz;
  v_ts_selesai timestamptz;
  v_sel int;
begin
  select j.kode into v_kode
  from jadwal j
  where j.karyawan_id = p_karyawan
    and j.periode = to_char(p_tanggal, 'YYYY-MM')
    and j.tanggal::int = extract(day from p_tanggal)::int
  limit 1;

  select i.mulai, i.selesai into v_mulai, v_selesai from absen_jam_shift(v_kode, p_tanggal) i;

  if v_mulai is null then
    return query select v_kode, 'tanpa_jadwal'::text, null::int, false, true;
    return;
  end if;

  v_ts_mulai   := (p_tanggal + v_mulai) at time zone 'Asia/Jakarta';
  v_ts_selesai := ((p_tanggal + case when v_selesai <= v_mulai then 1 else 0 end) + v_selesai)
                  at time zone 'Asia/Jakarta';

  if p_jenis = 'masuk' then
    v_sel := round(extract(epoch from (p_waktu - v_ts_mulai)) / 60)::int;
    return query select v_kode,
      (case when v_sel > p_toleransi then 'terlambat' else 'tepat_waktu' end)::text,
      v_sel, abs(v_sel) > 120, false;
  else
    v_sel := round(extract(epoch from (p_waktu - v_ts_selesai)) / 60)::int;
    return query select v_kode,
      (case when v_sel < 0 then 'pulang_cepat' else 'tepat_waktu' end)::text,
      v_sel, abs(v_sel) > 120, false;
  end if;
end $$;


-- ---------------------------------------------------------------------
--  6. PERSETUJUAN FOTO & LOKASI
-- ---------------------------------------------------------------------
drop function if exists setujui_absen_privasi(text, text);
create or replace function setujui_absen_privasi(p_versi text, p_user_agent text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if id_saya() is null then
    raise exception 'Akunmu belum terhubung ke data karyawan.';
  end if;
  insert into absen_persetujuan (karyawan_id, versi, ip, user_agent)
  values (id_saya(), p_versi, absen_ip(), left(p_user_agent, 300))
  on conflict (karyawan_id, versi) do nothing;
end $$;


-- ---------------------------------------------------------------------
--  7. CATAT ABSEN -- satu-satunya jalan karyawan menulis ke tabel absen
-- ---------------------------------------------------------------------
drop function if exists catat_absen(text, double precision, double precision, numeric, text, boolean, text, text, text);
create or replace function catat_absen(
  p_jenis            text,
  p_lat              double precision,
  p_lng              double precision,
  p_akurasi          numeric,
  p_foto_path        text,
  p_dinas_luar       boolean default false,
  p_keterangan_dinas text default null,
  p_device_id        text default null,
  p_user_agent       text default null
)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_kid     uuid := id_saya();
  v_set     pengaturan_absen%rowtype;
  v_waktu   timestamptz := now();
  v_lokal   timestamp := now() at time zone 'Asia/Jakarta';
  v_tanggal date;
  v_jarak   numeric;
  v_hit     record;
  v_anomali text[] := '{}';
  v_ip      text := absen_ip();
  v_id      uuid;
begin
  if v_kid is null then
    raise exception 'Akunmu belum terhubung ke data karyawan.';
  end if;
  if p_jenis not in ('masuk', 'pulang') then
    raise exception 'Jenis absen tidak dikenal.';
  end if;
  if not exists (select 1 from absen_persetujuan where karyawan_id = v_kid) then
    raise exception 'Setujui dulu penggunaan foto dan lokasi untuk absen.';
  end if;
  if p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Lokasi tidak valid. Aktifkan lokasi lalu coba lagi.';
  end if;
  if p_foto_path is null or p_foto_path not like v_kid::text || '/%' then
    raise exception 'Foto absen tidak valid. Ambil ulang fotonya.';
  end if;
  if p_dinas_luar and btrim(coalesce(p_keterangan_dinas, '')) = '' then
    raise exception 'Dinas luar wajib diisi keterangannya.';
  end if;

  select * into v_set from pengaturan_absen where id;

  v_tanggal := case when p_jenis = 'pulang'
                    then absen_tanggal_shift(v_kid, v_lokal)
                    else v_lokal::date end;

  if exists (select 1 from absen where karyawan_id = v_kid and tanggal = v_tanggal and jenis = p_jenis) then
    raise exception 'Kamu sudah absen % hari ini.', p_jenis;
  end if;

  -- Jarak ke outlet (haversine), dihitung di server.
  if v_set.lokasi_outlet_lat is not null and v_set.lokasi_outlet_lng is not null then
    v_jarak := round((6371000 * 2 * asin(sqrt(
        power(sin(radians(p_lat - v_set.lokasi_outlet_lat::double precision) / 2), 2)
      + cos(radians(v_set.lokasi_outlet_lat::double precision)) * cos(radians(p_lat))
        * power(sin(radians(p_lng - v_set.lokasi_outlet_lng::double precision) / 2), 2)
    )))::numeric, 1);

    if v_jarak > v_set.radius_m and not p_dinas_luar then
      if v_set.blok_di_luar_radius then
        raise exception 'Kamu berada % m dari outlet (maksimal % m). Absen ditolak. Kalau sedang bertugas di luar, pilih Dinas luar.',
          round(v_jarak), v_set.radius_m;
      end if;
      v_anomali := array_append(v_anomali, 'di_luar_radius');
    end if;
  end if;

  if p_akurasi is null or p_akurasi > v_set.akurasi_gps_maks_m then
    v_anomali := array_append(v_anomali, 'akurasi_gps_buruk');
  end if;

  -- Perangkat yang sama dipakai karyawan lain di hari yang sama: tandai dua-duanya.
  if p_device_id is not null and exists (
       select 1 from absen where device_id = p_device_id and tanggal = v_tanggal and karyawan_id <> v_kid) then
    v_anomali := array_append(v_anomali, 'device_dipakai_banyak_orang');
    update absen set anomali = array_append(anomali, 'device_dipakai_banyak_orang')
    where device_id = p_device_id and tanggal = v_tanggal and karyawan_id <> v_kid
      and not ('device_dipakai_banyak_orang' = any(anomali));
  end if;

  -- IP baru (informasi saja): baru dinilai kalau sudah ada >= 3 riwayat ber-IP.
  if v_ip is not null
     and (select count(*) from absen where karyawan_id = v_kid and ip is not null
            and tanggal > v_tanggal - 30) >= 3
     and not exists (select 1 from absen where karyawan_id = v_kid and ip = v_ip
            and tanggal > v_tanggal - 30) then
    v_anomali := array_append(v_anomali, 'ip_berbeda_dari_biasanya');
  end if;

  select * into v_hit
  from absen_hitung(v_kid, v_tanggal, p_jenis, v_waktu, v_set.toleransi_terlambat_menit);

  if v_hit.r_tanpa_jadwal then
    v_anomali := array_append(v_anomali, 'tanpa_jadwal');
  end if;
  if v_hit.r_jauh then
    v_anomali := array_append(v_anomali, 'waktu_jauh_dari_shift');
  end if;
  if p_jenis = 'pulang' and not exists (
       select 1 from absen where karyawan_id = v_kid and tanggal = v_tanggal and jenis = 'masuk') then
    v_anomali := array_append(v_anomali, 'tanpa_absen_masuk');
  end if;

  begin
    insert into absen (
      karyawan_id, tanggal, jenis, waktu, lat, lng, akurasi_m, jarak_dari_outlet_m,
      foto_path, kode_shift, status, selisih_menit, dinas_luar, keterangan_dinas,
      anomali, ip, device_id, user_agent
    ) values (
      v_kid, v_tanggal, p_jenis, v_waktu, p_lat, p_lng, p_akurasi, v_jarak,
      p_foto_path, v_hit.r_kode, v_hit.r_status, v_hit.r_selisih_menit,
      coalesce(p_dinas_luar, false), nullif(btrim(coalesce(p_keterangan_dinas, '')), ''),
      v_anomali, v_ip, left(p_device_id, 100), left(p_user_agent, 300)
    ) returning id into v_id;
  exception when unique_violation then
    raise exception 'Kamu sudah absen % hari ini.', p_jenis;
  end;

  return json_build_object(
    'id', v_id, 'jenis', p_jenis, 'tanggal', v_tanggal, 'waktu', v_waktu,
    'status', v_hit.r_status, 'selisih_menit', v_hit.r_selisih_menit,
    'kode_shift', v_hit.r_kode, 'jarak_m', v_jarak, 'anomali', to_json(v_anomali)
  );
end $$;


-- ---------------------------------------------------------------------
--  8. STATUS ABSEN HARI INI -- untuk tombol besar di halaman Absen
-- ---------------------------------------------------------------------
drop function if exists status_absen_hari_ini();
create or replace function status_absen_hari_ini()
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_kid    uuid := id_saya();
  v_lokal  timestamp := now() at time zone 'Asia/Jakarta';
  v_tgl    date;
  v_set    pengaturan_absen%rowtype;
  v_kode   text;
  v_mulai  time;
  v_selesai time;
  v_masuk  absen%rowtype;
  v_pulang absen%rowtype;
begin
  if v_kid is null then return null; end if;

  v_tgl := absen_tanggal_shift(v_kid, v_lokal);
  select * into v_set from pengaturan_absen where id;

  select j.kode into v_kode
  from jadwal j
  where j.karyawan_id = v_kid and j.periode = to_char(v_tgl, 'YYYY-MM')
    and j.tanggal::int = extract(day from v_tgl)::int
  limit 1;

  select i.mulai, i.selesai into v_mulai, v_selesai from absen_jam_shift(v_kode, v_tgl) i;
  select * into v_masuk  from absen where karyawan_id = v_kid and tanggal = v_tgl and jenis = 'masuk';
  select * into v_pulang from absen where karyawan_id = v_kid and tanggal = v_tgl and jenis = 'pulang';

  return json_build_object(
    'setuju', exists (select 1 from absen_persetujuan where karyawan_id = v_kid),
    'tanggal', v_tgl,
    'kode_shift', v_kode,
    'jam_shift', case when v_mulai is null then null
                      else to_char(v_mulai, 'HH24.MI') || '–' || to_char(v_selesai, 'HH24.MI') end,
    'masuk', case when v_masuk.id is null then null else json_build_object(
        'waktu', v_masuk.waktu, 'status', v_masuk.status,
        'selisih_menit', v_masuk.selisih_menit, 'anomali', to_json(v_masuk.anomali)) end,
    'pulang', case when v_pulang.id is null then null else json_build_object(
        'waktu', v_pulang.waktu, 'status', v_pulang.status,
        'selisih_menit', v_pulang.selisih_menit, 'anomali', to_json(v_pulang.anomali)) end,
    'outlet_diatur', v_set.lokasi_outlet_lat is not null and v_set.lokasi_outlet_lng is not null,
    'pulang_wajib', v_set.absen_pulang_wajib
  );
end $$;


-- ---------------------------------------------------------------------
--  9. KOREKSI ABSEN
-- ---------------------------------------------------------------------
drop function if exists ajukan_koreksi_absen(date, text, time, text);
create or replace function ajukan_koreksi_absen(
  p_tanggal date, p_jenis text, p_jam time, p_alasan text
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kid   uuid := id_saya();
  v_hari  date := (now() at time zone 'Asia/Jakarta')::date;
  v_id    uuid;
begin
  if v_kid is null then raise exception 'Akunmu belum terhubung ke data karyawan.'; end if;
  if p_jenis not in ('masuk', 'pulang') then raise exception 'Jenis absen tidak dikenal.'; end if;
  if p_jam is null then raise exception 'Isi jam yang benar.'; end if;
  if btrim(coalesce(p_alasan, '')) = '' then raise exception 'Alasan wajib diisi.'; end if;
  if p_tanggal > v_hari then raise exception 'Tanggal koreksi tidak boleh di masa depan.'; end if;
  if p_tanggal < v_hari - 31 then raise exception 'Koreksi hanya bisa diajukan untuk 31 hari terakhir.'; end if;
  if exists (select 1 from absen_koreksi where karyawan_id = v_kid and tanggal = p_tanggal
              and jenis = p_jenis and status = 'menunggu') then
    raise exception 'Sudah ada pengajuan koreksi yang menunggu untuk absen itu.';
  end if;

  insert into absen_koreksi (karyawan_id, tanggal, jenis, jam_diajukan, alasan)
  values (v_kid, p_tanggal, p_jenis, p_jam, btrim(p_alasan))
  returning id into v_id;
  return v_id;
end $$;


drop function if exists putuskan_koreksi_absen(uuid, boolean, text);
create or replace function putuskan_koreksi_absen(
  p_id uuid, p_setuju boolean, p_balasan text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  k         absen_koreksi%rowtype;
  v_set     pengaturan_absen%rowtype;
  v_owner   uuid := id_saya();
  v_kode    text;
  v_mulai   time;
  v_selesai time;
  v_ts      timestamptz;
  v_hit     record;
  v_anomali text[] := '{}';
  v_ada     uuid;
begin
  if peran_saya() <> 'OWNER' then
    raise exception 'Cuma Owner yang boleh memutuskan koreksi absen.';
  end if;

  select * into k from absen_koreksi where id = p_id for update;
  if k.id is null then raise exception 'Pengajuan koreksi tidak ditemukan.'; end if;
  if k.status <> 'menunggu' then raise exception 'Pengajuan ini sudah diputuskan.'; end if;

  if not p_setuju then
    update absen_koreksi set status = 'ditolak', diputuskan_oleh = v_owner,
           balasan = nullif(btrim(coalesce(p_balasan, '')), ''), diputuskan_pada = now()
    where id = p_id;
    return;
  end if;

  select * into v_set from pengaturan_absen where id;

  select j.kode into v_kode
  from jadwal j
  where j.karyawan_id = k.karyawan_id and j.periode = to_char(k.tanggal, 'YYYY-MM')
    and j.tanggal::int = extract(day from k.tanggal)::int
  limit 1;
  select i.mulai, i.selesai into v_mulai, v_selesai from absen_jam_shift(v_kode, k.tanggal) i;

  -- Jam pulang yang lebih awal dari jam mulai shift = sudah lewat tengah malam.
  v_ts := (k.tanggal + k.jam_diajukan) at time zone 'Asia/Jakarta';
  if k.jenis = 'pulang' and v_mulai is not null and k.jam_diajukan < v_mulai then
    v_ts := ((k.tanggal + 1) + k.jam_diajukan) at time zone 'Asia/Jakarta';
  end if;

  select * into v_hit
  from absen_hitung(k.karyawan_id, k.tanggal, k.jenis, v_ts, v_set.toleransi_terlambat_menit);

  if v_hit.r_tanpa_jadwal then v_anomali := array_append(v_anomali, 'tanpa_jadwal'); end if;
  if v_hit.r_jauh then v_anomali := array_append(v_anomali, 'waktu_jauh_dari_shift'); end if;

  select id into v_ada from absen
  where karyawan_id = k.karyawan_id and tanggal = k.tanggal and jenis = k.jenis;

  if v_ada is null then
    insert into absen (karyawan_id, tanggal, jenis, waktu, kode_shift, status, selisih_menit,
                       anomali, hasil_koreksi, ditinjau_oleh, ditinjau_pada)
    values (k.karyawan_id, k.tanggal, k.jenis, v_ts, v_hit.r_kode, v_hit.r_status, v_hit.r_selisih_menit,
            v_anomali, true, v_owner, now());
  else
    update absen set
      waktu = v_ts, kode_shift = v_hit.r_kode, status = v_hit.r_status,
      selisih_menit = v_hit.r_selisih_menit, hasil_koreksi = true,
      anomali = (select coalesce(array_agg(x), '{}'::text[]) from unnest(anomali) x
                 where x not in ('tanpa_jadwal', 'waktu_jauh_dari_shift')) || v_anomali,
      ditinjau_oleh = v_owner, ditinjau_pada = now()
    where id = v_ada;
  end if;

  -- Absen pulang yang baru dikoreksi: tanda "tidak ada absen pulang" di absen masuk gugur.
  if k.jenis = 'pulang' then
    update absen set anomali = array_remove(anomali, 'tidak_ada_absen_pulang')
    where karyawan_id = k.karyawan_id and tanggal = k.tanggal and jenis = 'masuk';
  end if;

  update absen_koreksi set status = 'disetujui', diputuskan_oleh = v_owner,
         balasan = nullif(btrim(coalesce(p_balasan, '')), ''), diputuskan_pada = now()
  where id = p_id;
end $$;


-- ---------------------------------------------------------------------
--  10. OWNER: tinjau anomali, hitung anomali menunggu (untuk lonceng)
-- ---------------------------------------------------------------------
drop function if exists tinjau_absen(uuid);
create or replace function tinjau_absen(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if peran_saya() <> 'OWNER' then
    raise exception 'Cuma Owner yang boleh menandai anomali ditinjau.';
  end if;
  update absen set ditinjau_oleh = id_saya(), ditinjau_pada = now()
  where id = p_id and ditinjau_pada is null;
end $$;


-- mendesak = anomali belum ditinjau yang sudah >= 5 hari DAN fotonya masih ada
-- (foto terhapus di hari ke-7, jadi tinggal 2 hari lagi untuk melihatnya).
drop function if exists absen_anomali_menunggu();
create or replace function absen_anomali_menunggu()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if peran_saya() <> 'OWNER' then
    return json_build_object('total', 0, 'mendesak', 0);
  end if;
  return json_build_object(
    'total', (select count(*) from absen
              where cardinality(anomali) > 0 and ditinjau_pada is null),
    'mendesak', (select count(*) from absen
                 where cardinality(anomali) > 0 and ditinjau_pada is null
                   and foto_path is not null
                   and waktu <= now() - interval '5 days')
  );
end $$;


-- Daftar anomali yang belum ditinjau (terbaru dulu) -- untuk tab Anomali Owner.
drop function if exists absen_anomali_daftar();
create or replace function absen_anomali_daftar()
returns setof absen
language sql stable security definer set search_path = public as $$
  select * from absen
  where peran_saya() = 'OWNER' and cardinality(anomali) > 0 and ditinjau_pada is null
  order by waktu desc
  limit 300
$$;


-- ---------------------------------------------------------------------
--  11. REKAP PER KARYAWAN PER PERIODE -- untuk halaman Owner dan modul gaji
--      Perhitungan gaji yang sekarang TIDAK diubah.
--      menit_terlambat = menit setelah jam mulai (bukan setelah toleransi),
--      dijumlahkan hanya untuk absen masuk berstatus terlambat.
-- ---------------------------------------------------------------------
drop function if exists rekap_absen_periode(text);
create or replace function rekap_absen_periode(p_periode text)
returns table (
  karyawan_id uuid, nama text,
  hari_masuk int, menit_terlambat int, jumlah_terlambat int,
  hari_pulang_cepat int, hari_tanpa_pulang int, hari_dinas_luar int,
  jumlah_anomali int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if peran_saya() not in ('OWNER', 'FINANCE') then
    raise exception 'Rekap absen hanya untuk Owner dan Finance.';
  end if;
  return query
  select k.id, k.nama,
         (count(a.id) filter (where a.jenis = 'masuk'))::int,
         (coalesce(sum(greatest(a.selisih_menit, 0))
                   filter (where a.jenis = 'masuk' and a.status = 'terlambat'), 0))::int,
         (count(a.id) filter (where a.jenis = 'masuk' and a.status = 'terlambat'))::int,
         (count(a.id) filter (where a.jenis = 'pulang' and a.status = 'pulang_cepat'))::int,
         (count(a.id) filter (where a.jenis = 'masuk'
                              and 'tidak_ada_absen_pulang' = any(a.anomali)))::int,
         (count(a.id) filter (where a.jenis = 'masuk' and a.dinas_luar))::int,
         (count(a.id) filter (where cardinality(a.anomali) > 0))::int
  from karyawan k
  left join absen a on a.karyawan_id = k.id and to_char(a.tanggal, 'YYYY-MM') = p_periode
  where k.peran <> 'OWNER'
  group by k.id, k.nama
  order by k.nama;
end $$;


-- ---------------------------------------------------------------------
--  12. DIPANGGIL JOB HARIAN (Edge Function absen-bersih, bukan dari aplikasi)
--      Menandai absen masuk kemarin dan sebelumnya yang tidak punya pulang.
-- ---------------------------------------------------------------------
drop function if exists periksa_absen_pulang();
create or replace function periksa_absen_pulang()
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not (select absen_pulang_wajib from pengaturan_absen where id) then
    return 0;
  end if;
  update absen m set anomali = array_append(m.anomali, 'tidak_ada_absen_pulang')
  where m.jenis = 'masuk'
    and m.tanggal < (now() at time zone 'Asia/Jakarta')::date
    and not ('tidak_ada_absen_pulang' = any(m.anomali))
    and not exists (select 1 from absen p
                    where p.karyawan_id = m.karyawan_id and p.tanggal = m.tanggal and p.jenis = 'pulang');
  get diagnostics v_n = row_count;
  return v_n;
end $$;


-- ---------------------------------------------------------------------
--  13. HAK AKSES FUNGSI
--      Fungsi bantu = internal. Fungsi aplikasi = hanya yang sudah login.
--      periksa_absen_pulang = hanya job (service_role).
-- ---------------------------------------------------------------------
revoke execute on function absen_ip() from public, anon, authenticated;
revoke execute on function absen_jam_shift(text, date) from public, anon, authenticated;
revoke execute on function absen_tanggal_shift(uuid, timestamp) from public, anon, authenticated;
revoke execute on function absen_hitung(uuid, date, text, timestamptz, int) from public, anon, authenticated;

revoke execute on function setujui_absen_privasi(text, text) from public, anon;
grant  execute on function setujui_absen_privasi(text, text) to authenticated;
revoke execute on function catat_absen(text, double precision, double precision, numeric, text, boolean, text, text, text) from public, anon;
grant  execute on function catat_absen(text, double precision, double precision, numeric, text, boolean, text, text, text) to authenticated;
revoke execute on function status_absen_hari_ini() from public, anon;
grant  execute on function status_absen_hari_ini() to authenticated;
revoke execute on function ajukan_koreksi_absen(date, text, time, text) from public, anon;
grant  execute on function ajukan_koreksi_absen(date, text, time, text) to authenticated;
revoke execute on function putuskan_koreksi_absen(uuid, boolean, text) from public, anon;
grant  execute on function putuskan_koreksi_absen(uuid, boolean, text) to authenticated;
revoke execute on function tinjau_absen(uuid) from public, anon;
grant  execute on function tinjau_absen(uuid) to authenticated;
revoke execute on function absen_anomali_menunggu() from public, anon;
grant  execute on function absen_anomali_menunggu() to authenticated;
revoke execute on function absen_anomali_daftar() from public, anon;
grant  execute on function absen_anomali_daftar() to authenticated;
revoke execute on function rekap_absen_periode(text) from public, anon;
grant  execute on function rekap_absen_periode(text) to authenticated;
revoke execute on function periksa_absen_pulang() from public, anon, authenticated;
grant  execute on function periksa_absen_pulang() to service_role;


-- ---------------------------------------------------------------------
--  14. BUCKET FOTO (privat) + aturan akses
--      Karyawan hanya boleh mengunggah ke folder bernama id miliknya sendiri.
--      Hanya Owner yang boleh melihat. Tidak ada yang boleh menghapus dari
--      aplikasi -- penghapusan 7 hari dikerjakan Edge Function (service_role).
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('absen-foto', 'absen-foto', false, 2097152, array['image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "absen foto: unggah ke folder sendiri" on storage.objects;
create policy "absen foto: unggah ke folder sendiri" on storage.objects for insert to authenticated
  with check (bucket_id = 'absen-foto' and (storage.foldername(name))[1] = id_saya()::text);

drop policy if exists "absen foto: lihat owner" on storage.objects;
create policy "absen foto: lihat owner" on storage.objects for select to authenticated
  using (bucket_id = 'absen-foto' and peran_saya() = 'OWNER');


notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select * from pengaturan_absen;                       -- 1 baris, koordinat masih kosong
-- select * from storage.buckets where id = 'absen-foto'; -- public = false
-- select rls_aktif from (select relrowsecurity as rls_aktif from pg_class
--   where relname in ('absen','absen_koreksi','pengaturan_absen','absen_persetujuan')) x;
