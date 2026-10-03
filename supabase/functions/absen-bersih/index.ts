// Job harian absen kehadiran (jalan lewat Cron Supabase, mis. 05.00 WIB):
//  1. Hapus foto absen yang sudah lewat masa simpan (pengaturan_absen.retensi_foto_hari,
//     bawaan 7 hari) dari bucket "absen-foto", lalu kosongkan foto_path dan isi
//     foto_dihapus_pada di tabel absen. Data absennya (waktu, lokasi, status) TETAP.
//  2. Tandai absen masuk yang tidak punya absen pulang (periksa_absen_pulang()).
//
// Aman dijalankan berulang. Memakai service role, yang otomatis tersedia di
// Edge Function (SUPABASE_URL & SUPABASE_SERVICE_ROLE_KEY) -- tidak perlu
// menyimpan kunci apa pun secara manual.
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "absen-foto";

// Tanggal hari ini di WIB (UTC+7), format YYYY-MM-DD.
const tanggalWIB = (offsetHari = 0) =>
  new Date(Date.now() + 7 * 3600_000 + offsetHari * 86_400_000).toISOString().slice(0, 10);

Deno.serve(async () => {
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  try {
    const { data: set, error: eSet } = await sb
      .from("pengaturan_absen").select("retensi_foto_hari").eq("id", true).single();
    if (eSet) throw eSet;
    const retensi = set.retensi_foto_hari ?? 7;
    // Foto tanggal D dihapus ketika hari ini - D >= retensi.
    const batas = tanggalWIB(-retensi);

    const daftar = async (path: string) => {
      const semua: { name: string; id: string | null }[] = [];
      for (let offset = 0; ; offset += 1000) {
        const { data, error } = await sb.storage.from(BUCKET).list(path, { limit: 1000, offset });
        if (error) throw error;
        semua.push(...(data ?? []));
        if (!data || data.length < 1000) break;
      }
      return semua;
    };

    // Struktur file: <karyawan_id>/<YYYY-MM-DD>/<masuk|pulang>-<waktu>.jpg
    // Hapus semua file di folder tanggal yang sudah lewat batas -- termasuk
    // foto yatim (terunggah tapi absennya gagal tersimpan).
    const hapusPath: string[] = [];
    for (const folderKaryawan of (await daftar("")).filter((x) => x.id === null)) {
      for (const folderTanggal of (await daftar(folderKaryawan.name)).filter((x) => x.id === null)) {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(folderTanggal.name) || folderTanggal.name > batas) continue;
        const dir = `${folderKaryawan.name}/${folderTanggal.name}`;
        for (const f of (await daftar(dir)).filter((x) => x.id !== null)) hapusPath.push(`${dir}/${f.name}`);
      }
    }

    let fileDihapus = 0;
    for (let i = 0; i < hapusPath.length; i += 100) {
      const potong = hapusPath.slice(i, i + 100);
      const { error } = await sb.storage.from(BUCKET).remove(potong);
      if (error) throw error;
      fileDihapus += potong.length;
      const { error: eUpd } = await sb.from("absen")
        .update({ foto_path: null, foto_dihapus_pada: new Date().toISOString() })
        .in("foto_path", potong);
      if (eUpd) throw eUpd;
    }

    // Jaring pengaman: baris yang fotonya sudah tidak ada di storage tapi
    // foto_path-nya masih terisi (mis. file dihapus manual) -- kosongkan juga.
    const { error: eSisa } = await sb.from("absen")
      .update({ foto_path: null, foto_dihapus_pada: new Date().toISOString() })
      .not("foto_path", "is", null)
      .lte("tanggal", tanggalWIB(-(retensi + 2)));
    if (eSisa) throw eSisa;

    const { data: ditandai, error: ePulang } = await sb.rpc("periksa_absen_pulang");
    if (ePulang) throw ePulang;

    const hasil = { ok: true, batas_tanggal_foto: batas, file_dihapus: fileDihapus, absen_ditandai_tanpa_pulang: ditandai };
    console.log(JSON.stringify(hasil));
    return new Response(JSON.stringify(hasil), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("[absen-bersih] gagal:", e);
    return new Response(JSON.stringify({ ok: false, error: String((e as Error)?.message ?? e) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
