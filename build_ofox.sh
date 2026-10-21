#!/usr/bin/env bash
# build_ofox.sh - Build OrangeFox 12.1 recovery Samsung A02 (MT6739, kernel 64-bit) dari nol sampai jadi .img
# Hasil akhir: $REPO/OrangeFox-a02-new.img (di root repo, *.img lama dihapus), siap di-download dari file manager Codespaces.
# Jalankan dari root repo device tree:
#   ./build_ofox.sh            -> semua step berurutan: deps, sync, tree, build
#   ./build_ofox.sh deps       -> install build tools
#   ./build_ofox.sh sync       -> sync source OrangeFox ke $FOX_DIR
#   ./build_ofox.sh tree       -> inject file kustom + patch BoardConfig.mk (di repo), lalu sync ke tree build
#   ./build_ofox.sh build      -> tree + build incremental (mka) + trim ramdisk + repack header v2 -> .img di root repo
# Opsi env: FOX_BRANCH=12.1  FOX_DIR=/abs/path (default /tmp/OrangeFox_<branch>)  JOBS=4

set -o pipefail

FOX_BRANCH="${FOX_BRANCH:-12.1}"
FOX_DIR="${FOX_DIR:-/tmp/OrangeFox_${FOX_BRANCH}}"
DEVICE="a02"
DEVICE_PATH="device/samsung/a02"
DEV="$FOX_DIR/$DEVICE_PATH"
PART_MAX=25165824   # partisi recovery 24MB
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/build_ofox.log"
IMG_NAME="OrangeFox-a02-new.img"

die() { echo "ERROR: $*" >&2; exit 1; }

step_deps() {
  echo "== [1/4] Install build tools"
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs \
    gnupg gperf imagemagick lib32ncurses-dev lib32readline-dev lib32z1-dev \
    libc6-dev-i386 libgl1-mesa-dev liblz4-tool libncurses-dev libssl-dev \
    libxml2 libxml2-utils lzop pngcrush python3 python-is-python3 rsync schedtool \
    squashfs-tools unzip x11proto-core-dev libx11-dev xsltproc zip zlib1g-dev fontconfig \
    || die "apt gagal"
  # Ubuntu 24.04 (noble) tidak punya libncurses5/libtinfo5, tapi prebuilt tools Android 12 butuh -> ambil dari jammy
  if ! ldconfig -p | grep -q 'libtinfo.so.5'; then
    local base=http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses d
    d=$(mktemp -d)
    for p in libtinfo5 libncurses5; do
      f=$(curl -fsSL "$base/" | grep -oE "${p}_6\.3-2ubuntu0\.[0-9]+_amd64\.deb" | sort -V | tail -1)
      [ -n "$f" ] && curl -fsSL "$base/$f" -o "$d/$f" || echo "WARNING: gagal ambil $p dari jammy"
    done
    sudo dpkg -i "$d"/*.deb || echo "WARNING: install libncurses5/libtinfo5 gagal"
  fi
  mkdir -p "$HOME/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo" || die "download repo gagal"
  chmod a+x "$HOME/bin/repo"
  export PATH="$HOME/bin:$PATH"
  git config --global user.name  >/dev/null || git config --global user.name  "rdbckp"
  git config --global user.email >/dev/null || git config --global user.email "rdbckp@users.noreply.github.com"
  git config --global color.ui false
}

step_sync() {
  echo "== [2/4] Sync OrangeFox ${FOX_BRANCH} -> $FOX_DIR"
  export PATH="$HOME/bin:$PATH"
  local avail_gb
  avail_gb=$(df -BG --output=avail "$(dirname "$FOX_DIR")" | tail -1 | tr -dc '0-9')
  echo "Ruang kosong: ${avail_gb}GB (sync + build 12.1 butuh ~40-60GB)"
  [ "${avail_gb:-0}" -ge 40 ] || echo "WARNING: ruang disk mepet, kemungkinan gagal"
  [ -d "$HOME/fox-sync/.git" ] || git clone --depth=1 https://gitlab.com/OrangeFox/sync.git "$HOME/fox-sync" || die "clone sync gagal"
  (cd "$HOME/fox-sync" && git pull --ff-only || true)
  mkdir -p "$FOX_DIR"
  (cd "$HOME/fox-sync" && ./orangefox_sync.sh --branch "$FOX_BRANCH" --path "$FOX_DIR") || die "sync gagal"
  [ -f "$FOX_DIR/build/envsetup.sh" ] || die "sync gagal, build/envsetup.sh tidak ada"
}

step_tree() {
  echo "== [3/4] Inject file kustom + patch BoardConfig.mk, sync ke $DEV"
  cd "$REPO" || die "repo tidak ketemu"
  [ -f BoardConfig.mk ] || die "BoardConfig.mk tidak ketemu di $REPO (jalankan script dari root repo device tree)"
  mkdir -p "$(dirname recovery/root/init.recovery.usb.rc)" && cat > recovery/root/init.recovery.usb.rc <<'FIXEOF'
on boot
    setprop sys.usb.configfs 1
    setprop sys.usb.ffs.aio_compat 1
    setprop vendor.usb.controller "musb-hdrc"
    setprop vendor.usb.acm_cnt 0
    start usbfix

service usbfix /system/bin/sh /system/bin/usbfix.sh
    disabled
    user root
    group root
    oneshot
    seclabel u:r:recovery:s0

on property:sys.usb.config=none && property:sys.usb.configfs=1
    write /config/usb_gadget/g1/UDC "none"
    rm /config/usb_gadget/g1/configs/b.1/f1
    rm /config/usb_gadget/g1/configs/b.1/f2

on property:sys.usb.config=adb && property:sys.usb.configfs=1
    start adbd

on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1
    mkdir /config/usb_gadget/g1/functions/mtp.gs0
    start adbd
    wait /dev/usb-ffs/adb/ep2 10
    write /config/usb_gadget/g1/idVendor 0x04e8
    write /config/usb_gadget/g1/idProduct 0x6860
    write /config/usb_gadget/g1/configs/b.1/strings/0x409/configuration "mtp,adb"
    symlink /config/usb_gadget/g1/functions/mtp.gs0 /config/usb_gadget/g1/configs/b.1/f1
    symlink /config/usb_gadget/g1/functions/ffs.adb /config/usb_gadget/g1/configs/b.1/f2
    write /config/usb_gadget/g1/UDC ${sys.usb.controller}
    setprop sys.usb.state ${sys.usb.config}
FIXEOF
  mkdir -p "$(dirname recovery/root/init.recovery.mt6739.rc)" && cat > recovery/root/init.recovery.mt6739.rc <<'FIXEOF'
on init
    setprop sys.usb.configfs 1
    setprop sys.usb.ffs.aio_compat 1
    # Force touch sensor biar tetap nyala
    write /sys/class/sec/tsp/input/enabled 1

    exec u:r:recovery:s0 -- /sbin/mntl_link

on post-fs-data
    # Support A/B feature for boot region
    symlink /dev/block/mmcblk0boot0 /dev/block/platform/bootdevice/by-name/preloader_a
    symlink /dev/block/mmcblk0boot1 /dev/block/platform/bootdevice/by-name/preloader_b

    exec u:r:update_engine:s0 root root -- /system/bin/mtk_plpath_utils

on fs
    # Set charging free dan inisialisasi USB
    # cmode 2 = USB disconnect; di-handle usbfix.sh (cmode 1 setelah UDC bind)
    
    # Fix MTP Samsung biar kedeteksi di Windows
    setprop sys.usb.config mtp,adb
    setprop sys.usb.state mtp,adb
    
    start adbd

on boot
    # Tambahan pemicu buat touchscreen driver Samsung
    chown system system /sys/class/sec/tsp/cmd
    chmod 0660 /sys/class/sec/tsp/cmd
    write /sys/class/sec/tsp/input/enabled 1
FIXEOF
  mkdir -p "$(dirname recovery/root/system/bin/usbfix.sh)" && cat > recovery/root/system/bin/usbfix.sh <<'FIXEOF'
#!/system/bin/sh
# Jaga gadget tetap ke-bind: adbd restart (service.adb.root) bikin FFS close -> UDC ke-unbind.
# Tiap UDC kosong dan syarat siap, bind ulang lalu cmode 1 supaya musb kirim event connect.
G=/config/usb_gadget/g1
U=/sys/class/udc/musb-hdrc
L=/tmp/usbfix.log
echo "usbfix start" > $L
while true; do
  if [ "$(getprop sys.usb.config)" = "mtp,adb" ] && [ -e $G/configs/b.1/f1 ] && [ -e $G/configs/b.1/f2 ] && [ -e /dev/usb-ffs/adb/ep2 ]; then
    if [ -z "$(cat $G/UDC 2>/dev/null)" ]; then
      echo "$(date +%s) UDC kosong, bind ulang" >> $L
      echo musb-hdrc > $G/UDC 2>>$L
      sleep 1
      echo 1 > $U/device/cmode 2>>$L
      echo "$(date +%s) state=$(cat $U/state)" >> $L
    fi
  fi
  sleep 1
done
FIXEOF
  mkdir -p "$(dirname recovery/root/system/etc/init/hw/init.rc)" && cat > recovery/root/system/etc/init/hw/init.rc <<'FIXEOF'
import /init.recovery.logd.rc
import /init.recovery.ldconfig.rc
import /init.recovery.mksh.rc
import /init.recovery.usb.rc
import /init.recovery.service.rc
import /init.recovery.${ro.hardware}.rc

on early-init
    # Set the security context of /postinstall if present.
    restorecon /postinstall

    # ueventd wants to write to /acct
    mount cgroup none /acct cpuacct
    mkdir /acct/uid
    # Copy prebuilt ld.config.txt into linkerconfig directory
    copy /system/etc/ld.config.txt /linkerconfig/ld.config.txt
    chmod 444 /linkerconfig/ld.config.txt

    start ueventd

    setprop sys.usb.configfs 0

on init
    export PATH /sbin:/system/bin
    export LD_LIBRARY_PATH /system/lib64:/vendor/lib64/hw

    export ANDROID_ROOT /system
    export ANDROID_DATA /data
    export EXTERNAL_STORAGE /sdcard

    symlink /proc/self/fd/0 /dev/stdin
    symlink /proc/self/fd/1 /dev/stdout
    symlink /proc/self/fd/2 /dev/stderr

    symlink /system/bin /bin
    symlink /system/etc /etc

    mount cgroup none /acct cpuacct
    mkdir /acct/uid

    mkdir /sdcard
    mkdir /system
    mkdir /data
    symlink /data/cache /cache
    mkdir /sideload
    mkdir /mnt/system
    mount tmpfs tmpfs /tmp

    chown root shell /tmp
    chmod 0775 /tmp
    mkdir /tmp/misc
    mkdir /tmp/misc/keystore/

    write /proc/sys/kernel/panic_on_oops 1
    write /proc/sys/vm/max_map_count 1000000

    mkdir /dev/binderfs
    mount binder binder /dev/binderfs stats=global
    chmod 0755 /dev/binderfs
    chmod 0666 /dev/binderfs/hwbinder
    chmod 0666 /dev/binderfs/binder
    chmod 0666 /dev/binderfs/vndbinder
    symlink /dev/binderfs/binder /dev/binder
    symlink /dev/binderfs/hwbinder /dev/hwbinder
    symlink /dev/binderfs/vndbinder /dev/vndbinder

    # Create location for fs_mgr to store abbreviated output from filesystem
    # checker programs.
    mkdir /dev/fscklogs 0770 root system

on boot
    ifup lo
    hostname localhost
    domainname localdomain

    class_start default

on firmware_mounts_complete
    rm /dev/.booting

# Mount filesystems and start core system services.
on late-init
    trigger early-fs
    trigger fs
    trigger post-fs
    trigger post-fs-data

    # Remove a file to wake up anything waiting for firmware
    trigger firmware_mounts_complete

    trigger early-boot
    trigger boot

on post-fs-data
    # Set fscklog permission
    chown root system /dev/fscklogs/log
    chmod 0770 /dev/fscklogs/log

service ueventd /system/bin/ueventd
    critical
    seclabel u:r:ueventd:s0

service adbd /system/bin/adbd --root_seclabel=u:r:su:s0 --device_banner=recovery
    disabled
    socket adbd stream 660 system system
    seclabel u:r:adbd:s0

# Always start adbd on userdebug and eng builds
on property:ro.debuggable=1
    #write /sys/class/android_usb/android0/enable 1
    #start adbd
    setprop service.adb.root 1

# Always start adbd on userdebug and eng builds
on fs && property:ro.debuggable=1
    setprop sys.usb.config adb

service fastbootd /system/bin/fastbootd
    disabled
    group system
    seclabel u:r:fastbootd:s0

# Restart adbd so it can run as root
on property:service.adb.root=1
    restart adbd

on fs && property:sys.usb.configfs=1
    mount configfs none /config
    mkdir /config/usb_gadget/g1 0770 shell shell
    write /config/usb_gadget/g1/idVendor 0x18D1
    mkdir /config/usb_gadget/g1/strings/0x409 0770
    write /config/usb_gadget/g1/strings/0x409/serialnumber ${ro.serialno}
    write /config/usb_gadget/g1/strings/0x409/manufacturer ${ro.product.manufacturer}
    write /config/usb_gadget/g1/strings/0x409/product ${ro.product.model}
    mkdir /config/usb_gadget/g1/functions/ffs.adb
    mkdir /config/usb_gadget/g1/functions/ffs.fastboot
    mkdir /config/usb_gadget/g1/configs/b.1 0777 shell shell
    mkdir /config/usb_gadget/g1/configs/b.1/strings/0x409 0770 shell shell

on fs && property:sys.usb.configfs=0
    write /sys/class/android_usb/android0/f_ffs/aliases adb,fastboot
    write /sys/class/android_usb/android0/idVendor 18D1
    write /sys/class/android_usb/android0/iManufacturer ${ro.product.manufacturer}
    write /sys/class/android_usb/android0/iProduct ${ro.product.model}
    write /sys/class/android_usb/android0/iSerial ${ro.serialno}

on fs
    mount pstore pstore /sys/fs/pstore
    mkdir /dev/usb-ffs 0770 shell shell
    mkdir /dev/usb-ffs/adb 0770 shell shell
    mount functionfs adb /dev/usb-ffs/adb uid=2000,gid=2000
    mkdir /dev/usb-ffs/fastboot 0770 system system
    mount functionfs fastboot /dev/usb-ffs/fastboot rmode=0770,fmode=0660,uid=1000,gid=1000

on property:sys.usb.config=adb
    start adbd

on property:sys.usb.config=fastboot
    start fastbootd

on property:sys.usb.config=none && property:sys.usb.configfs=0
    stop adbd
    stop fastbootd
    write /sys/class/android_usb/android0/enable 0
    setprop sys.usb.state ${sys.usb.config}

on property:sys.usb.config=adb && property:sys.usb.configfs=0
    write /sys/class/android_usb/android0/idProduct D001
    write /sys/class/android_usb/android0/functions adb
    write /sys/class/android_usb/android0/enable 1
    setprop sys.usb.state ${sys.usb.config}

on property:sys.usb.config=sideload && property:sys.usb.configfs=0
    write /sys/class/android_usb/android0/idProduct D001
    write /sys/class/android_usb/android0/functions adb
    write /sys/class/android_usb/android0/enable 1
    setprop sys.usb.state ${sys.usb.config}

on property:sys.usb.config=fastboot && property:sys.usb.configfs=0
    write /sys/class/android_usb/android0/idProduct 4EE0
    write /sys/class/android_usb/android0/functions fastboot
    write /sys/class/android_usb/android0/enable 1
    setprop sys.usb.state ${sys.usb.config}

# Configfs triggers
on property:sys.usb.config=none && property:sys.usb.configfs=1
    write /config/usb_gadget/g1/UDC "none"
    stop adbd
    stop fastbootd
    setprop sys.usb.ffs.ready 0
    rm /config/usb_gadget/g1/configs/b.1/f1
    setprop sys.usb.state ${sys.usb.config}

on property:sys.usb.config=sideload && property:sys.usb.ffs.ready=1 && property:sys.usb.configfs=1
    write /config/usb_gadget/g1/idProduct 0xD001
    write /config/usb_gadget/g1/configs/b.1/strings/0x409/configuration "adb"
    symlink /config/usb_gadget/g1/functions/ffs.adb /config/usb_gadget/g1/configs/b.1/f1
    write /config/usb_gadget/g1/UDC ${sys.usb.controller}
    setprop sys.usb.state ${sys.usb.config}

on property:sys.usb.config=adb && property:sys.usb.ffs.ready=1 && property:sys.usb.configfs=1
    write /config/usb_gadget/g1/idProduct 0xD001
    write /config/usb_gadget/g1/configs/b.1/strings/0x409/configuration "adb"
    symlink /config/usb_gadget/g1/functions/ffs.adb /config/usb_gadget/g1/configs/b.1/f1
    write /config/usb_gadget/g1/UDC ${sys.usb.controller}
    setprop sys.usb.state ${sys.usb.config}

on property:sys.usb.config=fastboot && property:sys.usb.ffs.ready=1 && property:sys.usb.configfs=1
    write /config/usb_gadget/g1/idProduct 0x4EE0
    write /config/usb_gadget/g1/configs/b.1/strings/0x409/configuration "fastboot"
    symlink /config/usb_gadget/g1/functions/ffs.fastboot /config/usb_gadget/g1/configs/b.1/f1
    write /config/usb_gadget/g1/UDC ${sys.usb.controller}
    setprop sys.usb.state ${sys.usb.config}
FIXEOF
  chmod 755 recovery/root/system/bin/usbfix.sh
  # patch BoardConfig.mk (idempotent): ramdisk gzip (kernel gak support LZMA), crypto off (device tanpa enkripsi),
  # board C003 + bootopt sesuai img fixed, mount point extra Samsung
  local B=BoardConfig.mk
  sed -i -e 's/^BOARD_RAMDISK_USE_LZMA := true/BOARD_RAMDISK_USE_LZMA := false/' \
         -e 's/^LZMA_RAMDISK_TARGETS/#&/' \
         -e 's/^TW_INCLUDE_CRYPTO/#&/' \
         -e 's/^TW_INCLUDE_FBE_METADATA_DECRYPT/#&/' \
         -e 's/SRPTK19C000SA/SRPTK19C003/' "$B"
  grep -q 'bootopt=' "$B" || sed -i 's/^BOARD_KERNEL_CMDLINE := /BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 /' "$B"
  grep -q 'BOARD_ROOT_EXTRA_FOLDERS' "$B" || echo 'BOARD_ROOT_EXTRA_FOLDERS := efs metadata omr optics prism' >> "$B"
  mkdir -p "$DEV"
  rsync -a --delete --exclude='.git' --exclude='.github' --exclude='/*.sh' --exclude='*.img' --exclude='*.zip' "$REPO/" "$DEV/" || die "rsync gagal"
  grep -nE 'LZMA|CRYPTO|KERNEL_CMDLINE|--board|ROOT_EXTRA' "$B"
}

step_build() {
  echo "== [4/4] Build OrangeFox (incremental) + trim + repack"
  cd "$FOX_DIR" || die "$FOX_DIR tidak ada, jalankan step sync dulu"
  # shellcheck disable=SC1091
  source build/envsetup.sh
  export ALLOW_MISSING_DEPENDENCIES=true LC_ALL=C FOX_MAINTAINER_PATCH_VERSION=1 FOX_BUILD_TYPE=Unofficial OF_MAINTAINER=rdbckp
  unset FOX_VERSION
  lunch fox_a02-eng || die "lunch gagal"
  local o=out/target/product/$DEVICE r h=out/host/linux-x86/bin
  r=$o/recovery/root
  rm -rf "$r"; rm -f $o/ramdisk-recovery.* $o/recovery.img $o/OrangeFox-*.img $o/OrangeFox-*.zip
  # mka sengaja gak di-die-kan: image bawaan AOSP bisa gagal di cek ukuran (ramdisk belum di-trim),
  # yang dipakai nanti hasil repack manual di bawah
  mka adbd recoveryimage -j"${JOBS:-4}" 2>&1 | tee -a "$LOG"
  [ -d "$r/system" ] && [ -f "$o/kernel" ] && [ -f "$o/ramdisk-recovery.img" ] || die "mka gagal sebelum ramdisk jadi (log: $LOG)"
  # trim ramdisk biar muat partisi: buang lib/binary yang gak ada di img fixed + bahasa selain en/id
  (cd "$r" && rm -f system/lib64/{libicui18n,libicuuc,libandroidicu,libncurses}.so \
      system/lib64/libclang_rt.ubsan_standalone-aarch64-android.so sbin/bash sbin/zip \
    && find twres/languages -type f ! -name en.xml ! -name id_ID.xml -delete)
  $h/mkbootfs -d $o/system "$r" | $h/minigzip > $o/ramdisk-recovery.img || die "pack ramdisk gagal"
  $h/mkbootimg --kernel $o/kernel --ramdisk $o/ramdisk-recovery.img \
    --cmdline "bootopt=64S3,32N2,64N2 androidboot.hardware=mt6739 buildvariant=eng" \
    --base 0x40000000 --pagesize 2048 --header_version 2 \
    --recovery_dtbo $DEVICE_PATH/prebuilt/dtbo \
    --kernel_offset 0x00080000 --ramdisk_offset 0x05000000 --tags_offset 0x04000000 \
    --dtb $DEVICE_PATH/prebuilt/dtb/dtb.dtb --dtb_offset 0x04000000 \
    --board SRPTK19C003 --output $o/recovery.img || die "mkbootimg gagal"
  local s; s=$(stat -c%s $o/recovery.img)
  echo "recovery.img: $s byte (max $PART_MAX)"
  [ "$s" -le "$PART_MAX" ] || die "image kegedean buat partisi recovery"
  rm -f "$REPO"/*.img && cp -v $o/recovery.img "$REPO/$IMG_NAME" || die "copy ke repo gagal"
  echo "SELESAI. Hasil: $REPO/$IMG_NAME"
}

case "${1:-all}" in
  deps)  step_deps ;;
  sync)  step_sync ;;
  tree)  step_tree ;;
  build) step_tree; step_build ;;
  all)   step_deps; step_sync; step_tree; step_build ;;
  *)     die "step tidak dikenal: $1 (deps|sync|tree|build)" ;;
esac

# clear && while true; do echo "Keep-alive: $(date)"; sleep 300; done
