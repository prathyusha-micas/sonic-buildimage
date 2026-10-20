#!/usr/bin/env bash
set -euo pipefail

: "${SONIC_CI_ROOT:?Set the SONIC_CI_ROOT repository variable}"
: "${CI_OUTPUT_DIR:?Set CI_OUTPUT_DIR}"
: "${SOURCE_REF:?Set SOURCE_REF}"
case "$SOURCE_REF" in
    prathyusha/practice-bgp-startup-log) ;;
    *) echo 'Only the reviewed practice branch is allowed.' >&2; exit 1 ;;
esac

mkdir -p "$SONIC_CI_ROOT" "$CI_OUTPUT_DIR"
exec > >(tee "$CI_OUTPUT_DIR/build.log") 2>&1
exec 9>"$SONIC_CI_ROOT/build.lock"
flock -n 9 || { echo 'Another practice build is running.'; exit 1; }

repo_url=https://github.com/prathyusha-micas/sonic-buildimage.git
source_dir="$SONIC_CI_ROOT/source"
baseline=7fa9354652d1d2e7759ee600be195c4bcd7e192e
seed_root="${SONIC_SEED_ROOT:-}"
free_kib=$(df -Pk "$SONIC_CI_ROOT" | awk 'NR==2 {print $4}')
if (( free_kib < 80 * 1024 * 1024 )); then
    echo 'At least 80 GiB free is required for this seeded incremental build.'
    exit 1
fi
docker info >/dev/null

if [[ ! -d "$source_dir/.git" ]]; then
    if [[ -n "$seed_root" ]] && git -C "$seed_root" rev-parse --git-dir >/dev/null 2>&1; then
        # Copy Git objects, without sharing writable files or alternate paths.
        git clone --quiet --no-hardlinks --no-checkout "$seed_root" "$source_dir"
        git -C "$source_dir" remote set-url origin "$repo_url"
    else
        git clone --quiet --depth 1 --branch "$SOURCE_REF" "$repo_url" "$source_dir"
    fi
fi
git -C "$source_dir" fetch --no-tags origin "$SOURCE_REF"
git -C "$source_dir" checkout --detach FETCH_HEAD
git -C "$source_dir" merge-base --is-ancestor "$baseline" HEAD
cd "$source_dir"

# Seed submodule Git objects locally; checkout still uses the committed gitlinks.
while read -r _ path; do
    if [[ ! -e "$path/.git" && -n "$seed_root" ]] &&
       git -C "$seed_root/$path" rev-parse --git-dir >/dev/null 2>&1; then
        mkdir -p "$(dirname "$path")"
        git clone --quiet --no-hardlinks --no-checkout "$seed_root/$path" "$path"
    fi
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
git submodule update --init --recursive --jobs 2
git submodule sync --recursive

if [[ ! -f "$SONIC_CI_ROOT/cache-seeded" && -n "$seed_root" ]] &&
   [[ "$(git -C "$seed_root" rev-parse HEAD)" == "$baseline" ]]; then
    mkdir -p target
    rsync -a --ignore-existing \
      --exclude='debs/*/frr*' --exclude='docker-fpm-frr*' \
      --exclude='sonic-broadcom*' --exclude='*.log' \
      "$seed_root/target/" target/
    for config_file in .platform .arch; do
        if [[ -f "$seed_root/$config_file" ]]; then
            cp -p "$seed_root/$config_file" "$config_file"
        fi
    done
    touch "$SONIC_CI_ROOT/cache-seeded"
fi

make configure PLATFORM=broadcom
if [[ -n "$seed_root" && -f "$seed_root/.platform" ]] && cmp -s .platform "$seed_root/.platform"; then
    touch -r "$seed_root/.platform" .platform
fi
make SONIC_BUILD_JOBS=1 SONIC_DPKG_CACHE_METHOD=none \
  SONIC_BUILD_VARS='SONIC_CONFIG_MAKE_JOBS=2' target/sonic-broadcom.bin

# Verify that the built package really contains the exercise before publishing.
verify_dir=$(mktemp -d "$SONIC_CI_ROOT/verify-frr.XXXXXX")
dpkg-deb -x target/debs/trixie/frr_10.5.4-sonic-0_amd64.deb "$verify_dir"
grep -aFq 'BGP-LEARNING-TEST: custom bgpd build started (Prathyusha)' "$verify_dir/usr/lib/frr/bgpd"
cp target/sonic-broadcom.bin "$CI_OUTPUT_DIR/sonic-broadcom.bin"
(
    cd "$CI_OUTPUT_DIR"
    sha256sum sonic-broadcom.bin > SHA256SUMS
)
{
    printf 'Repository: %s\nBranch: %s\n' "$repo_url" "$SOURCE_REF"
    printf 'Commit: %s\n' "$(git rev-parse HEAD)"
    printf 'Platform: broadcom\nFRR: 10.5.4\nStartup marker: verified\n'
    git submodule status src/sonic-frr/frr
} > "$CI_OUTPUT_DIR/build-manifest.txt"
cp target/sonic-broadcom.bin.log "$CI_OUTPUT_DIR/image-build.log"
printf 'Image built and startup marker verified.\n'
