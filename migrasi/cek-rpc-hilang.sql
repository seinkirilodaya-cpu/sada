-- =====================================================================
--  CUMA MELIHAT -- tidak mengubah apa pun.
--  Membandingkan SEMUA fungsi (RPC) yang dipanggil kode aplikasi Sada
--  (56 nama) dengan fungsi yang benar-benar ada di database Sada.
--  Jalankan di Supabase SADA → SQL Editor, lalu kirim seluruh hasilnya.
--
--  ada = false  -> fungsinya belum ada di database (pasti error 404/PGRST202)
--  argumen      -> parameter fungsi yang ada; dibandingkan dengan cara kode memanggilnya
-- =====================================================================
with dipanggil(nama) as (values
  ('absen_anomali_daftar'),
  ('absen_anomali_menunggu'),
  ('ajukan_koreksi_absen'),
  ('aktifkan_karyawan'),
  ('anggota_divisi_saya'),
  ('bahan_dipakai_menu'),
  ('bahan_jejak'),
  ('bahan_ringkas_pakai'),
  ('belanja_alasan'),
  ('belanja_kurang'),
  ('belanja_menggantung'),
  ('belanja_perjalanan'),
  ('belanja_ringkas'),
  ('buatkan_akun'),
  ('catat_absen'),
  ('daftar_beans'),
  ('daftar_belanja_hari_ini'),
  ('daftar_nama'),
  ('daftar_susu'),
  ('dial_acuan_bahan'),
  ('dial_hari_ini'),
  ('dial_riwayat'),
  ('dial_terbuang'),
  ('dial_terbuang_total'),
  ('finalisasi_opname'),
  ('ganti_nama_karyawan'),
  ('ganti_pin'),
  ('hapus_permintaan'),
  ('harga_naik'),
  ('harga_ringkas'),
  ('jejak_baris'),
  ('jejak_cari'),
  ('jejak_ringkas'),
  ('karyawan_dipakai'),
  ('menu_dipakai'),
  ('menu_terdampak'),
  ('nonaktifkan_karyawan'),
  ('opex_periode'),
  ('opname_finalisasi_status'),
  ('peer_sudah'),
  ('produksi_bahan_rinci'),
  ('produksi_buang_ringkas'),
  ('produksi_daftar'),
  ('produksi_kadaluarsa'),
  ('produksi_ringkas'),
  ('putuskan_absen'),
  ('putuskan_koreksi_absen'),
  ('rekap_absen_periode'),
  ('resep_produksi_daftar'),
  ('setujui_absen_privasi'),
  ('status_absen_hari_ini'),
  ('tambah_karyawan'),
  ('tambah_kemasan_bahan'),
  ('tandai_absen_dilihat'),
  ('tinjau_absen'),
  ('tutup_permintaan')
)
select d.nama,
       (p.oid is not null) as ada,
       pg_get_function_arguments(p.oid) as argumen
from dipanggil d
left join pg_proc p on p.proname = d.nama and p.pronamespace = 'public'::regnamespace
order by ada, d.nama;
