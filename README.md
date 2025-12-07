# Storage Migration + Post-migration Utility
Versiune: 2.1  
Autor: karen20ced4

Acest README descrie comenzile de utilizare pentru:
- `storage-migrate.sh` — scriptul principal de migrare (root / LVM) (rămâne neschimbat, rulezi manual).
- `post-migration.sh` — script auxiliar de post-migrare (fix-uri resume, fstab, rebuild initramfs/grub, audit).

Ambele scripturi păstrează loguri și backup-uri în:
- Backup & metadata: `/root/storage-migrate-backups/`
  - metadata: `/root/storage-migrate-backups/migration-metadata.json`
  - fstab backup: `/root/storage-migrate-backups/fstab.new.backup.*`
  - post-migration log: `/root/storage-migrate-backups/post-migration.log`
- Log principal script: `/var/log/storage-migrate.log` (sau `/tmp/storage-migrate.log` dacă nu exista permisiune)

---

## 1. Cerințe (Debian/Ubuntu)
Instalează pachetele necesare:
```sh
apt update
apt install -y parted rsync lvm2 grub-pc-bin grub-efi-amd64-bin dosfstools util-linux coreutils gawk e2fsprogs
```

Verifică comenzi utilizabile:
```sh
command -v parted lsblk rsync mkfs.ext4 mkswap pvcreate vgextend pvmove vgreduce blkid grub-install update-grub mkfs.fat partprobe udevadm pvs vgs lvs findmnt mount umount chroot blockdev df mountpoint awk e2fsck
```

---

## 2. storage-migrate.sh — moduri / comenzi frecvente

Fișierul principal: `storage-migrate.sh`  
Permite: dry-run, migrare root-only / lvm-only / full-disk, resume pvmove.

Ajutor:
```sh
sudo ./storage-migrate.sh --help
```

Verificare (CHECK, doar analiză, nicio modificare):
```sh
sudo ./storage-migrate.sh --check
```

Mod RESUME (reluează pvmove salvat în `/root/storage-migrate-backups/lvm-resume.sh`):
```sh
sudo ./storage-migrate.sh --resume
```

Rulare normală (interactiv, urmezi pașii):
```sh
sudo ./storage-migrate.sh
```

- În timpul execuției vei fi întrebat pentru alegerea disk-urilor, dimensiune root etc.
- Scriptul face backup fstab original în `${BACKUP_DIR}` înainte de a modifica.
- Dacă scriptul eșuează la pvmove, va scrie un script de reluare în `${BACKUP_DIR}/lvm-resume.sh`.

Log:
- Output interactiv + detaliat este salvat în `/var/log/storage-migrate.log`.
- Backup-uri și metadata în `/root/storage-migrate-backups/`.

Recomandare: rulează `--check` sau vizualizează DRY-RUN înainte de a confirma operațiunea.

---

## 3. post-migration.sh — ce face și când să-l rulezi

Fișier: `post-migration.sh` (versiuni: v2.1 implicit)

Scop:
- Aliniază/rescrie `RESUME=UUID=` în `/etc/initramfs-tools/conf.d/resume`
- (Opțional) sincronizează UUID swap în `/etc/fstab`
- Elimină/curăță `resume=` din GRUB
- Face `update-initramfs` și `update-grub` (în chroot sau pe sistemul real)
- Face `nofail,x-systemd.device-timeout=1s` pe /dev/sr0 (cdrom) sau comentează linia
- Blacklistează floppy (opțional)
- Log complet în `${ROOT}/root/storage-migrate-backups/post-migration.log`
- Afișează progres incremental (tabel de pași) — versiunea 2.1

Când să rulezi:
- Recomandat: în mod PRE-BOOT (în chroot) imediat după actualizarea `/mnt/newroot` și înainte de a face reboot. Astfel initramfs și grub sunt regenerate în noul root și primul boot nu va avea delay.
  - Exemplu: (după migrare și înainte de cleanup/mount umount)
    ```sh
    # presupunem că /mnt/newroot e montat și are pseudo-filesystems bind-mounted
    sudo cp post-migration.sh /mnt/newroot/usr/local/sbin/post-migration.sh
    sudo chroot /mnt/newroot /usr/local/sbin/post-migration.sh --preboot --fix-resume auto --fix-cdrom nofail --blacklist-floppy yes --sync-fstab-swap yes
    ```
- Alternativ: rulează post-boot pe sistemul nou (după primul boot) pentru audit/fix:
  ```sh
  sudo /usr/local/sbin/post-migration.sh --postboot --fix-resume auto --sync-fstab-swap yes --fix-cdrom nofail --blacklist-floppy yes
  ```

Opțiuni uzuale:
- `--preboot` — rulează ca în chroot (implicit dacă rulezi în chroot)
- `--postboot` — verificări pentru un sistem deja boot-at
- `--verbose` — afișează output complet și comenzi în timp real
- `--summary` — afișare concisă (implicit)
- `--quiet` — silențios (doar erori)
- `--fix-resume auto|disable|uuid=<UUID>` — ce să facă cu resume
- `--sync-fstab-swap yes|no` — dacă vrem alinierea liniilor swap din fstab
- `--fix-cdrom nofail|comment|keep` — cum tratăm `/dev/sr0` în fstab
- `--blacklist-floppy yes|no`
- `--quiet-boot yes|no` — adaugă `quiet loglevel=3` în GRUB (opțional)
- `--log <path>` — schimbă fișierul log

Exemple practice:
- Rulare summary (implicit):
  ```sh
  sudo ./post-migration.sh
  ```
- Rulare verbose (utile când vrei să vezi `update-initramfs` în timp real):
  ```sh
  sudo ./post-migration.sh --verbose
  ```
- Rulare post-boot (audit + fix):
  ```sh
  sudo ./post-migration.sh --postboot --fix-resume auto --sync-fstab-swap yes --fix-cdrom nofail --blacklist-floppy yes
  ```

Log implicit:
- `/root/storage-migrate-backups/post-migration.log`

---

## 4. Flux de lucru recomandat (rezumat)
1. Înainte de migrare: verifică `--check` și Dry-Run:
   ```sh
   sudo ./storage-migrate.sh --check
   ```
2. Rulează migrarea interactiv:
   ```sh
   sudo ./storage-migrate.sh
   ```
3. După ce scriptul a terminat (și înainte de poweroff / reboot), în contextul noului root montat la `/mnt/newroot`:
   - Copiază `post-migration.sh` în noul root și rulează-l în chroot:
     ```sh
     sudo cp post-migration.sh /mnt/newroot/usr/local/sbin/post-migration.sh
     sudo chroot /mnt/newroot /usr/local/sbin/post-migration.sh --preboot --fix-resume auto --sync-fstab-swap yes --fix-cdrom nofail --blacklist-floppy yes
     ```
   - Aceasta va actualiza resume, fstab swap, rebuild initramfs și grub în noul root.
4. Oprește și înlocuiește fizic discurile (sau ajustează configurația VM).
5. Pornește de pe noul disc; dacă ai rulat pasul 3 în chroot, ar trebui să nu mai existe delay la boot.
6. Dacă ai uitat să rulezi pasul 3, rulează `post-migration.sh` pe sistemul boot-at (post-boot) cu `--postboot`.

---

## 5. Verificări rapide & depanare

Verificări imediate:
```sh
# UUID swap activ
blkid -s UUID -o value /dev/sda3
# Resume configurat
cat /etc/initramfs-tools/conf.d/resume
# Verifică /etc/fstab
cat /etc/fstab
# Verifică if swap este activ
swapon --show
# Logs
tail -n 100 /var/log/storage-migrate.log
tail -n 200 /root/storage-migrate-backups/post-migration.log
```

Dacă `update-initramfs` sau `update-grub` eșuează:
- Verifică spațiu liber pe `/boot` și pe `/`:
  ```sh
  df -h /boot / || df -h /
  ```
- Reîncearcă cu reparații dpkg/apt:
  ```sh
  apt-get -f install
  dpkg --configure -a
  apt-get update
  apt-get --reinstall install initramfs-tools initramfs-tools-core
  # apoi:
  update-initramfs -u -k "$(uname -r)" -v
  update-grub
  ```
- Consultă logul complet `/root/storage-migrate-backups/post-migration.log`.

Dacă boot-ul stă la similarul:
```
sd 32:0:1:0: [sda] Assuming drive cache: write through
```
- Cel mai frecvent motiv este `resume` configurat cu un UUID vechi; rulează `post-migration.sh` pentru a actualiza `RESUME` și `update-initramfs`.
- Dacă problema persistă, caută în kernel log:
  ```sh
  journalctl -b -k | egrep -i 'resume|timeout|gave up|sr0|floppy|scsi|Assuming drive cache' -n
  ```

Workaround GRUB temporar:
- În meniul GRUB apasă `e` pe intrarea curentă și adaugă `noresume` la linia `linux` pentru a testa un boot fără resume.

---

## 6. Unde găsești fișierele generate

- Logs principale:
  - `/var/log/storage-migrate.log`
  - `/root/storage-migrate-backups/post-migration.log`
- Backups:
  - `/root/storage-migrate-backups/fstab.original.backup.*`
  - `/root/storage-migrate-backups/fstab.new.backup.*`
  - `/root/storage-migrate-backups/migration-metadata.json`
- Resume / resume-relate:
  - `/etc/initramfs-tools/conf.d/resume` (în rootul migrat — sau în noul root când rulezi în chroot)
- Resume reluare pvmove:
  - `/root/storage-migrate-backups/lvm-resume.sh`

---

## 7. Sfaturi și bune practici
- Nu șterge discul vechi până nu verifici complet că noul disc bootează și conținutul este corect.
- Păstrează backup-urile generate în `/root/storage-migrate-backups/`.
- Testează procesul într-o mașină virtuală înainte de a rula într-un mediu de producție.
- Rulează `post-migration.sh --verbose` dacă vrei să vezi exact ce face `update-initramfs` / `update-grub`.

---
