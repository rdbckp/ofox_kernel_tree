#!/usr/bin/env bash
# Build OrangeFox (Samsung A02, 64-bit) di Codespaces - setara build_ofox.yml
# Pakai: ./build_ofox.sh            (dari dalam repo device tree)
# Opsi env: FOX_BRANCH=12.1 FOX_VERSION=R12.1 FOX_DIR=/abs/path ./build_ofox.sh  (default /tmp/OrangeFox_<branch>)
# Opsi step: ./build_ofox.sh deps | sync | tree | build   (default: semuanya berurutan)

set -o pipefail

FOX_BRANCH="${FOX_BRANCH:-12.1}"
FOX_VERSION="${FOX_VERSION:-R12.1}"
FOX_DIR="${FOX_DIR:-/tmp/OrangeFox_${FOX_BRANCH}}"
DEVICE="a02"
DEVICE_PATH="device/samsung/a02"
PART_MAX=25165824   # partisi recovery 24MB
TREE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/build_ofox.log"

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
  echo "== [3/4] Pasang device tree dari $TREE_SRC -> $FOX_DIR/$DEVICE_PATH"
  [ -f "$TREE_SRC/BoardConfig.mk" ] || die "BoardConfig.mk tidak ketemu di $TREE_SRC (jalankan script dari dalam repo device tree)"
  mkdir -p "$FOX_DIR/$DEVICE_PATH"
  rsync -a --delete --exclude='.git' --exclude='.github' --exclude='*.sh' --exclude='*.zip' "$TREE_SRC/" "$FOX_DIR/$DEVICE_PATH/"
  ls -la "$FOX_DIR/$DEVICE_PATH" "$FOX_DIR/$DEVICE_PATH/prebuilt"
}

step_build() {
  echo "== [4/4] Build OrangeFox"
  cd "$FOX_DIR" || die "$FOX_DIR tidak ada, jalankan step sync dulu"
  set +e
  # shellcheck disable=SC1091
  source build/envsetup.sh
  export ALLOW_MISSING_DEPENDENCIES=true
  export LC_ALL=C
  export FOX_VERSION FOX_BUILD_TYPE="Unofficial" OF_MAINTAINER="rdbckp"
  lunch fox_a02-eng 2>&1 | tee "$LOG"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "lunch gagal (log: $LOG)"
  mka adbd recoveryimage -j"$(nproc --all)" 2>&1 | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "mka gagal (log: $LOG)"

  local out="$FOX_DIR/out/target/product/$DEVICE" dest="$HOME/ofox_output"
  mkdir -p "$dest"
  cp -v "$out"/OrangeFox-*.img "$out"/OrangeFox-*.zip "$dest/" 2>/dev/null
  [ -f "$out/recovery.img" ] && cp -v "$out/recovery.img" "$dest/"
  ls -lh "$dest"
  for f in "$dest"/*.img; do
    [ -f "$f" ] || die "tidak ada image hasil build"
    s=$(stat -c%s "$f"); echo "$(basename "$f"): $s byte (max $PART_MAX)"
    [ "$s" -le "$PART_MAX" ] || die "$(basename "$f") kegedean buat partisi recovery"
  done
  echo "SELESAI. Hasil di: $dest"
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