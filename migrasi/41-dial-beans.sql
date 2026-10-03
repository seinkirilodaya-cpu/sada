-- =====================================================================
--  DAFTAR BEANS UNTUK DROPDOWN DIAL IN
--  Jalankan sekali di Supabase SADA → SQL Editor. Aman dijalankan berulang.
--
--  Meniru daftar_susu() (migrasi 29). Filter lama (divisi = 'BAR' dan
--  satuan = 'GRAM') salah untuk Sada: satuan di master bahan Sada ditulis
--  'gr', jadi hasilnya kosong. Filter sekarang berdasarkan NAMA ("Beans ...")
--  dan hanya bahan yang aktif -- Beans Coldbrew yang nonaktif otomatis
--  tidak ikut muncul.
-- =====================================================================

drop function if exists daftar_beans();

create or replace function daftar_beans()
returns table (id uuid, nama text, satuan text)
language sql stable security definer set search_path = public as $$
  select b.id, b.nama, b.satuan
  from bahan b
  where b.aktif and b.divisi = 'BAR'
    and upper(b.nama) like '%BEANS%'
  order by b.nama
$$;

grant execute on function daftar_beans() to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
--  PEMERIKSAAN
-- =====================================================================
-- select * from daftar_beans();
-- Harusnya muncul: Beans Arabica, Beans Sample (Beans Coldbrew nonaktif).
