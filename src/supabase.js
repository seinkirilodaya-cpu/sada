import { createClient } from "@supabase/supabase-js";

// Alamat & kunci diambil dari berkas .env (lihat .env.example), bukan ditulis
// langsung di sini, supaya tidak ikut tersimpan ke git.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

// true kalau .env sudah diisi. App.jsx memakai ini untuk menampilkan layar
// penjelasan yang jelas kalau belum diisi, alih-alih halaman kosong tanpa keterangan.
export const supabaseSiap = Boolean(supabaseUrl && supabaseAnonKey);

export const supabase = createClient(
  supabaseUrl || "https://belum-disambungkan.supabase.co",
  supabaseAnonKey || "belum-disambungkan",
);
