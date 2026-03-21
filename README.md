# Storage Migration Scripts

Scripts de migrare disc pentru **Linux** (Bash) și **Windows** (PowerShell GUI).  
Suportă: SSD, NVMe, HDD, USB, LVM, NTFS, exFAT, ext4, UEFI și BIOS.

---

## Fișiere

| Fișier | Versiune | Platformă | Descriere |
|---|---|---|---|
| `storage-migrate.sh` | 3.1 | Linux | Script Bash — migrare OS + clonare disc cu progres hh:mm:ss |
| `storage-post-migration.sh` | 2.6 | Linux | Script Bash post-migrare: initramfs, GRUB, fstab, LVM |
| `storage-migrate.ps1` | 1.0 | Windows | Script PowerShell cu **interfață grafică** — migrare OS + clonare disc |

---

## ⭐ Windows — PowerShell GUI (`storage-migrate.ps1`)

Script PowerShell cu interfață grafică (Windows Forms) pentru Windows 10/11.

### Caracteristici

- 🖱️ **Interfață grafică** cu butoane — fără linie de comandă
- 📁 **Mod Migrare OS** — mută Windows pe un disc nou (partition + robocopy + bcdboot)
- 💿 **Mod Clonare disc** — copiere sector-cu-sector (echivalent `dd` pe Linux)
- 📊 **Progress bar** în timp real (0–100%)
- ⚡ **Viteză transfer** afișată în MB/s
- ⏱️ **Timp scurs** în format `hh:mm:ss`
- ⏳ **Timp rămas estimat** în format `hh:mm:ss`
- 🔍 **Mod Dry-Run** — simulare fără modificări pe disc
- 📋 **Log colorat** în interfață + fișier persistent
- 🔒 **Auto-elevare** la Administrator (prompt automat)

### Cerințe Windows

- Windows 10 / Windows 11 / Windows Server 2019+
- PowerShell 5.1+ (inclus în Windows 10/11)
- Drepturi de **Administrator** (scriptul cere automat)

### Utilizare

```powershell
# Metoda 1: Click dreapta pe fișier → "Run with PowerShell"

# Metoda 2: Din PowerShell (ca Administrator)
Set-ExecutionPolicy -Scope Process Bypass -Force
.\storage-migrate.ps1
```

### Mod Migrare OS (Windows)

1. Selectează **📁 Migrare OS** (radio button stânga)
2. Alege discul **sursă** (cel cu Windows curent)
3. Alege discul **destinație** (disc nou)
4. Apasă **▶ Pornire**
5. Confirmă avertismentul de ștergere
6. Urmărești progresul, viteza (MB/s), timpii (scurs / rămas)

**Ce face intern:**
- Detectează partițiile (EFI/MSR/OS/Recovery)
- Creează același layout pe discul destinație (diskpart)
- Copiază toate fișierele cu `robocopy /B /COPYALL` (backup mode)
- Instalează bootloader-ul Windows cu `bcdboot`

**Pași după migrare:**
1. Oprește calculatorul
2. Înlocuiește fizic discul (scoate sursa, pune destinația)
3. Pornește calculatorul — Windows bootează de pe discul nou

### Mod Clonare disc (Windows)

1. Selectează **💿 Clonare disc** (radio button dreapta)
2. Alege discul **sursă** (HDD/SSD cu date)
3. Alege discul **destinație** (cel puțin egal ca mărime)
4. Apasă **▶ Pornire**
5. Urmărești progress bar-ul cu MB/s și ETA hh:mm:ss

**Ce face intern:**
- Citește discul sursă sector-cu-sector (`\\.\PhysicalDriveN`)
- Scrie pe discul destinație sector-cu-sector (identic cu `dd bs=4M`)
- Actualizează progress bar din 500ms în 500ms
- Afișează viteza medie și ETA recalculate din 2 în 2 secunde

### Interfața grafică

```
┌──────────────────────────────────────────────────────────┐
│ 💾  Windows Storage Migration Tool  —  v1.0              │
├──────────────────────────────────────────────────────────┤
│  ● 📁 Migrare OS    ○ 💿 Clonare disc                   │
├──────────────────────────────────────────────────────────┤
│ Disc Sursă: [Disk 0 — 500 GB — Samsung SSD 860]    [⟳]  │
│ Disc Țintă: [Disk 1 — 2.0 TB — Seagate HDD]              │
├──── Partiții sursă ──────┬──── Partiții destinație ──────┤
│ # │ Tip   │ Marime │ ... │ # │ Tip   │ Marime │ ...       │
├──────────────────────────────────────────────────────────┤
│ ████████████████░░░░░░░░  64%                            │
│ Viteză: 112 MB/s  │ Copiat: 320 GB / 500 GB              │
│ ⏱ Timp scurs: 00:47:32  │  ⏳ Timp rămas: 00:26:44      │
├──────────────────────────────────────────────────────────┤
│ [00:12:05] [OK] Clonare sector-by-sector...               │
│ [00:13:10] [INFO] Viteză medie: 115 MB/s                  │
├──────────────────────────────────────────────────────────┤
│ [🔍 Dry-Run]              [▶ Pornire]  [✕ Anulare]       │
└──────────────────────────────────────────────────────────┘
```

### Log fișier

Log-ul se salvează automat în:
```
C:\ProgramData\storage-migrate-backups\migrate-YYYYMMDD-HHmmss.log
```

---

---

## Linux — Bash scripts

---

## Scenarii suportate (Linux)

### 1. Migrare disc root (SSD/NVMe intern → SSD/NVMe intern)
Copierea sistemului de operare Linux de pe un disc vechi pe unul nou.  
Suportă UEFI și BIOS, creează partiții noi, rsync, reinstalează GRUB, actualizează fstab.

### 2. Migrare LVM PV (`lvm-only`)
Mutarea unui Physical Volume LVM pe un nou disc fără oprirea serverului.  
Folosește `pvmove` — serverul rămâne pornit pe tot parcursul.

### 3. Migrare completă disc (root + LVM, `full-disk`)
Combină migrarea root cu migrarea LVM PV într-o singură operațiune.

### 4. ⭐ Clonare disc de date (`data-clone`) — NTFS, exFAT, USB HDD
**Scenariul principal: clonare HDD USB NTFS 4TB pe alt HDD USB NTFS 4TB.**

Dacă discul sursă nu conține sistemul de operare Linux (fără mount `/`, fără LVM), scriptul
detectează automat partiții de date (NTFS, exFAT, ext4 etc.) și efectuează o **clonare
sector-by-sector** cu `dd`.

- ✅ Funcționează pentru USB → USB
- ✅ Clonează orice sistem de fișiere (NTFS, exFAT, ext4, FAT32 etc.)
- ✅ Rulează automat `ntfsfix` pe partiții NTFS după clonare
- ✅ Nu modifică discul sursă
- ✅ Afișează progresul în timp real
- ⚠️ Necesită disc destinație **cel puțin la fel de mare** ca sursa
- ⚠️ 4TB ≈ 2–6 ore (depinde de viteza USB)

---

## Cerințe

### Sistem de operare
- Debian / Ubuntu (sau orice distribuție Linux cu `apt`)
- Rulat ca **root** (`sudo`)

### Pachete necesare (instalate automat dacă lipsesc)
```
parted util-linux rsync e2fsprogs lvm2 grub-common dosfstools
udev gawk ntfs-3g ntfsprogs
```

> **Notă**: `ntfs-3g` și `ntfsprogs` (care include `ntfsfix`) sunt necesare pentru scenariul NTFS.
> Le poți instala manual: `sudo apt-get install ntfs-3g ntfsprogs`

---

## Utilizare

### Clonare disc de date NTFS/USB (scenariul principal)

```bash
sudo bash storage-migrate.sh
```

1. Selectează discul **sursă** (HDD-ul cu datele originale)
2. Selectează discul **destinație** (HDD-ul pe care vrei să clonezi)
3. Scriptul detectează automat tipul `data-clone`
4. Confirmă operațiunea
5. Clonarea pornește cu `dd` — urmărești progresul în terminal

### Migrare sistem de operare (root/NVMe/SSD)

```bash
sudo bash storage-migrate.sh
```

### Verificare prealabilă (fără modificări)

```bash
sudo bash storage-migrate.sh --check
```

### Reluare pvmove întrerupt

```bash
sudo bash storage-migrate.sh --resume
```

### Mod debug (loguri detaliate)

```bash
sudo bash storage-migrate.sh --debug
```

### Ajutor

```bash
sudo bash storage-migrate.sh --help
```

---

## Post-migrare (numai pentru migrare OS)

Rulează **după** ce ai pornit sistemul pe noul disc:

```bash
sudo bash storage-post-migration.sh
```

**Opțiuni:**

```bash
# Mod verbose (afișează toate comenzile)
sudo bash storage-post-migration.sh --verbose

# Extinde automat LVM dacă există spațiu liber
sudo bash storage-post-migration.sh --extend-lvm auto

# Post-boot audit complet
sudo bash storage-post-migration.sh --postboot
```

> **Notă**: Pentru clonare disc de date (NTFS/exFAT), `storage-post-migration.sh` nu este
> necesar — nu există initramfs sau GRUB de actualizat.

---

## Scenariu detaliat: 2× HDD USB NTFS 4TB (clone)

### Situație
- `HDD_A` = `/dev/sdb` — 4TB, NTFS, conectat USB (cu date)
- `HDD_B` = `/dev/sdc` — 4TB, NTFS, conectat USB (gol sau cu date vechi)
- Vrei să clonezi `HDD_A` pe `HDD_B`

### Pași

```bash
# 1. Identifică discurile
lsblk -o NAME,SIZE,FSTYPE,TRAN,LABEL

# 2. Rulează scriptul ca root
sudo bash storage-migrate.sh

# 3. La prompt:
#    - Selectează /dev/sdb ca SURSĂ
#    - Selectează /dev/sdc ca DESTINAȚIE
#    - Scriptul detectează automat: "Tip migrare: CLONARE DISC DE DATE (ntfs)"
#    - Confirmă operațiunea

# 4. Urmărești progresul dd (actualizat din secundă în secundă):
#    1.0 GB/s, 100 GB copied, 3900 GB remaining...

# 5. La final, ntfsfix marchează partiția clonată ca curată

# 6. Verificare (opțional):
sudo ntfsfix -n /dev/sdc1     # verificare fără modificări
sudo mount -o ro /dev/sdc1 /mnt && ls /mnt && sudo umount /mnt
```

### Ce face scriptul intern

```
dd if=/dev/sdb of=/dev/sdc bs=4M conv=sync,noerror status=progress
sync
ntfsfix -d /dev/sdc1
```

---

## Scenarii de tip OS (SSD/NVMe intern)

### Migrare root-only (fără LVM)

```
SSD vechi (/dev/sda) → NVMe nou (/dev/nvme0n1)
```

Scriptul:
1. Creează tabel GPT pe NVMe
2. Creează partiții root + swap + ESP (UEFI) sau bios_grub (BIOS)
3. Formatează (ext4 + swap + fat32)
4. `rsync -aAXH` sistemul
5. Instalează GRUB în chroot
6. Actualizează fstab cu UUID-urile noi
7. Rulează `update-initramfs`

### Migrare LVM-only (online, fără downtime)

```
PV pe /dev/sda1 → PV pe /dev/sdb1
```

Scriptul folosește `pvmove` — serverul rămâne pornit.

### Migrare Full-Disk (root + LVM)

Combină ambele de mai sus.

---

## Fișiere generate

| Locație | Conținut |
|---|---|
| `/var/log/storage-migrate.log` | Log complet al migrării |
| `/root/storage-migrate-backups/` | Backup-uri fstab, metadata JSON, script resume |
| `/root/storage-migrate-backups/migration-metadata.json` | Metadata migrare (versiune, discuri, tip) |
| `/root/storage-migrate-backups/reinstall-grub-after-move.sh` | Script reinstalare GRUB (USB→intern) |
| `/root/storage-migrate-backups/post-migration.log` | Log post-migrare |

---

## Limitări cunoscute

| Scenariu | Status |
|---|---|
| Clonare NTFS USB → USB | ✅ Suportat (dd) |
| Clonare exFAT USB → USB | ✅ Suportat (dd) |
| Migrare root ext4 | ✅ Suportat |
| Migrare root xfs | ✅ Suportat (rsync) |
| LVM pvmove | ✅ Suportat |
| UEFI (GPT + ESP) | ✅ Suportat |
| BIOS (MBR/GPT + bios_grub) | ✅ Suportat |
| Disc sursă mai mare ca destinație (data-clone) | ❌ Blocat (dd necesită target ≥ sursă) |
| Disc sursă montat în timp ce se clonează | ⚠️ Scriptul încearcă demontare automată |
| Disc NTFS fără tabel de partiții (disc raw) | ⚠️ Nu este detectat automat |

---

## Troubleshooting

### Eroare: "Disk sursă pare gol"
Discul nu are partiții recunoscute. Verifică:
```bash
lsblk -f /dev/sdX
blkid /dev/sdX*
```

### Eroare: "Discul destinație este mai mic decât sursa"
Pentru data-clone (`dd`), destinația trebuie să aibă cel puțin aceeași capacitate.

### ntfsfix returnează warning
Normal după clonare. Partiția NTFS este marcată ca „murdară" de Windows când nu a fost
demontată corect. `ntfsfix -d` o marchează ca curată fără a modifica date.

### dd s-a oprit / întrerupt
Clonarea este idempotentă — poți relua de la 0. Nu există mecanism de resume pentru `dd`.

### pvmove întrerupt
```bash
sudo bash storage-migrate.sh --resume
```

---

## Note pentru AI / Contribuitori

> **IMPORTANT — Regulă de versionare:**
>
> De fiecare dată când modifici `storage-migrate.sh`:
> - Incrementează `SCRIPT_VERSION` cu **+0.1** (ex: 3.0 → 3.1)
> - Actualizează `SCRIPT_DATE` cu data curentă (format `YYYY-MM-DD`)
> - Actualizează comentariul din antet (linia `# Version:` și `# Date:`)
>
> De fiecare dată când modifici `storage-post-migration.sh`:
> - Incrementează `SCRIPT_VERSION` cu **+0.1** (ex: 2.5 → 2.6)
> - Actualizează comentariul din antet (`# Date:`)
>
> Ambele fișiere conțin comentariul: `# NOTE FOR AI: Increment version by +0.1 ...`

---

## Licență

Distribuie liber. Fără garanții. Testează întotdeauna pe sisteme ne-critice înainte.
