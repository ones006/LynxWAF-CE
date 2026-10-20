# LynxWAF Community Edition — Manual Operasional & Panduan Administrator (SOP)

Buku panduan ini merupakan **Standar Operasional Prosedur (SOP)** resmi bagi Administrator Sistem, DevSecOps, dan Network Engineer yang mengoperasikan **LynxWAF Community Edition (CE)** di lingkungan produksi.

---

## 1. Topologi & Arsitektur Jaringan

LynxWAF beroperasi sebagai **Inline Layer 7 Reverse Proxy & Web Application Firewall** di depan server aplikasi Anda:

```
                  ┌───────────────────────────────────────────────┐
                  │                 LynxWAF Node                  │
                  │                                               │
Internet Traffic  │   Port 80/443 (network_mode: "host")          │
─────────────────┼──► [OpenResty WAF Engine] ────────────────────┼──► Upstream Apps
                  │          │ (Lua / eBPF Filter)                │    (e.g., :8080)
                  │          ▼                                    │
                  │   [LynxWAF Go Daemon] ◄── Port 8379 (HTTPS)   │
                  │     (Control Plane)       (Web Cyber-SOC)     │
                  │          │                                    │
                  │          ├──► [MySQL 8.0] (Logs & Telemetry)  │
                  │          └──► [Redis 7] (State & Challenges)  │
                  └───────────────────────────────────────────────┘
```

### Mengapa Menggunakan `network_mode: "host"`?
Container Data Plane (`lynxwaf-openresty`) menggunakan mode jaringan host untuk:
1. **Preservasi Real Client IP**: Mencegah Source-NAT Docker sehingga IP asli penyerang tercatat langsung, bukan IP bridge `172.x.x.x`.
2. **Zero Overhead Network**: Melewati overhead virtual switch Docker untuk mencapai throughput inspeksi jutaan request per detik.

---

## 2. Persyaratan & Port Jaringan

Sebelum instalasi, pastikan firewall server mengizinkan akses ke port-port berikut:

| Port | Protokol | Visibilitas | Kegunaan |
| :--- | :--- | :--- | :--- |
| **80** | TCP | Publik (Internet) | HTTP Traffic & Verifikasi Let's Encrypt ACME Challenge |
| **443** | TCP | Publik (Internet) | HTTPS Traffic Reverse Proxy Terenkripsi (TLS 1.2 / 1.3) |
| **8379** | TCP | Terbatas / VPN / Admin | Akses Web Console Cyber-SOC LynxWAF |
| **33060** | TCP | Hanya Localhost (`127.0.0.1`) | Port debug Database MySQL (tidak terekspos keluar) |
| **6379** | TCP | Hanya Localhost (`127.0.0.1`) | Port Redis Cache (tidak terekspos keluar) |

---

## 3. SOP 1: Instalasi & Deployment Awal

### Metode A: 1-Line Quick Installer (Rekomendasi)
Jalankan di server Ubuntu/Debian/RHEL baru dengan hak akses root:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ones006/LynxWAF-CE/main/install.sh)"
```

### Metode B: Manual Deployment via Git Clone
```bash
# 1. Clone repositori ke direktori /opt/lynxwaf
git clone https://github.com/ones006/LynxWAF-CE.git /opt/lynxwaf
cd /opt/lynxwaf

# 2. Salin template environment dan sesuaikan
cp .env.example .env
chmod 600 .env

# 3. Jalankan container stack
docker compose up -d

# 4. Buat user administrator pertama kali
docker exec -it lynxwaf-daemon /app/LynxWaf create_default_user admin "PasswordKuatAdmin2026!"
```

---

## 4. SOP 2: Onboarding & Konfigurasi Situs Baru (Sites)

Untuk melindungi website atau API di belakang LynxWAF:

1. Buka browser dan login ke Web Console di `https://<IP_SERVER>:8379`.
2. Masuk ke menu **Sites ➔ Add Protected Site**.
3. Masukkan parameter situs:
   - **Domain**: Nama domain publik (contoh: `api.perusahaan.com` dan `web.perusahaan.com`).
   - **Upstream Type**: `HTTP` atau `HTTPS`.
   - **Upstream Address**: Alamat server backend Anda (contoh: `http://10.0.0.15:8080` atau `http://127.0.0.1:8080`).
   - **Protection Mode**:
     - **Monitoring Mode**: LynxWAF hanya mencatat serangan ke log tanpa memblokir request (sangat dianjurkan pada 24 jam pertama untuk analisa false positive).
     - **Blocking Mode**: LynxWAF langsung menolak serangan berbahaya dengan kode HTTP `403 Forbidden` dan halaman challenge/interception.
   - **SSL/TLS**: Aktifkan **Auto Let's Encrypt** jika ingin sertifikat SSL gratis terbit secara otomatis.
4. Klik tombol **Save & Apply**.
5. Arahkan DNS A-Record domain Anda ke IP Server LynxWAF.

---

## 5. SOP 3: Penanganan Insiden & Analisa Interception Logs

Jika ada laporan serangan atau komplain dari pengguna yang terblokir (*false positive*):

### 5.1 Melihat Log Penyerangan Real-Time
1. Masuk ke menu **Interception Logs** (`/report`).
2. Gunakan **Filter Rentang Waktu**: Pilih *Last 1 Hour*, *Today*, atau *Custom Range*.
3. Gunakan filter semantik kategori serangan:
   - `SQL Injection (SQLi)`
   - `Cross-Site Scripting (XSS)`
   - `Remote Code Execution (RCE)`
   - `Path Traversal / LFI`
   - `Bad Bot / Automated Scanner`

### 5.2 Membuka Blokir IP False Positive (Whitelist)
Jika ada request pengguna sah yang terblokir:
1. Klik pada baris log insiden untuk melihat rincian request (Header, Payload, URI, dan Rule ID yang terpicu).
2. Jika terbukti aman, buka menu **Rules ➔ Whitelist / Exclusion**.
3. Tambahkan Rule Exclusion:
   - Masukkan IP klien sah atau URL path spesifik (misal: `/webhook/payment`).
   - Tentukan rule ID yang diabaikan.
4. Simpan konfigurasi. Perubahan akan tersinkronisasi ke OpenResty engine dalam 1 detik tanpa reload service.

---

## 6. SOP 4: Backup & Restore Konfigurasi

### 6.1 Backup Data Rutin
Jalankan script backup atau perintah berikut:
```bash
# Backup file konfigurasi dan database WAF
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p /opt/lynxwaf/backups
docker exec lynxwaf-mysql mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" lynxwaf > /opt/lynxwaf/backups/db_${BACKUP_DATE}.sql
tar -czvf /opt/lynxwaf/backups/config_${BACKUP_DATE}.tar.gz /opt/lynxwaf/.env /opt/lynxwaf/data/sqlite /opt/lynxwaf/config
```

### 6.2 Prosedur Restore
```bash
# 1. Hentikan container stack
cd /opt/lynxwaf
docker compose down

# 2. Ekstrak file konfigurasi
tar -xzvf /opt/lynxwaf/backups/config_<DATE>.tar.gz -C /

# 3. Nyalakan stack kembali
docker compose up -d

# 4. Import database SQL
docker exec -i lynxwaf-mysql mysql -u root -p"$MYSQL_ROOT_PASSWORD" lynxwaf < /opt/lynxwaf/backups/db_<DATE>.sql
```

---

## 7. SOP 5: Pembaruan Versi (Update & Patching)

LynxWAF dirancang untuk pembaruan tanpa risiko kehilangan konfigurasi situs:

```bash
cd /opt/lynxwaf

# Metode 1: Menggunakan script update bawaan
bash update.sh

# Metode 2: Manual Pull & Recreate
docker compose pull
docker compose up -d --remove-orphans
```

Setelah update selesai, verifikasi integritas stack:
```bash
docker compose ps
./test_poc_simulation.sh http://127.0.0.1
```

---

## 8. Panduan Troubleshooting Cepat

| Gejala Masalah | Penyebab Umum | Solusi Cepat |
| :--- | :--- | :--- |
| **502 Bad Gateway** pada website | Server upstream mati atau firewall memblokir IP WAF | Periksa alamat backend di menu Sites. Pastikan service aplikasi backend berjalan dan bisa di-ping dari server WAF. |
| **Console Web 8379 tidak bisa dibuka** | Port 8379 belum dibuka di firewall cloud (AWS SG, GCP Firewall, dsb.) | Buka security group / firewall inbound rule untuk TCP port `8379`. |
| **Sertifikat Let's Encrypt gagal terbit** | Port 80 belum terarah ke server WAF atau domain DNS belum propagasi | Pastikan A Record domain sudah mengarah ke IP publik WAF dan port 80/tcp dapat diakses dari internet. |
| **Error: "MYSQL_ROOT_PASSWORD must be set"** | File `.env` belum ada atau variabel password kosong | Pastikan file `/opt/lynxwaf/.env` sudah ada dan memiliki isi variabel `MYSQL_ROOT_PASSWORD` dan `REDIS_PASSWORD`. |
