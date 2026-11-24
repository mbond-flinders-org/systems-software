#!/usr/bin/env bash
# =============================================================================
# COMP2812 / COMP9812 Systems Software — lab machine setup
#
# Turns a stock Ubuntu Server machine (a local VM, Oracle Always Free, or
# Azure for Students) into the lab environment. Every lab machine is built
# with this script, so every student has the same environment.
#
# Run it from the student account (NOT as root), with sudo:
#
#     sudo bash setup-lab-vm.sh
#
# It is safe to run again: re-running checks everything, fixes anything that
# is missing, and never deletes your work. If staff release an updated
# version during semester, download it and run it again.
#
# Supports x86_64 and ARM64 (aarch64). Built for Ubuntu Server 26.04 LTS;
# tested on 24.04 (see SETUP-NOTES.md).
# =============================================================================

set -uo pipefail

SCRIPT_VERSION="2027.3"
LOG=/var/log/systems-software-setup.log
HOSTNAME_WANTED="systems-software"
IMAGES=("docker.io/library/alpine" "docker.io/library/python:3-slim")
# Where `get-lab N` downloads lab N's files from (labN.tar.gz). CHECK BEFORE RELEASE.
LAB_FILES_URL="https://raw.githubusercontent.com/mbond-flinders-org/systems-software/main"
PACKAGES=(
  # editors, docs, everyday tools
  nano man-db manpages-dev less file curl xxd openssl
  # build and run code
  build-essential python3 python3-pytest time binutils
  # observing the system
  procps strace lsof iproute2 util-linux
  # filesystems, devices, permissions
  e2fsprogs acl
  # containers (rootless podman)
  podman uidmap
)

# ---- output helpers ---------------------------------------------------------
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok    %s\n' "$*"; }
warn() { printf '    WARN  %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\nSETUP STOPPED: %s\n' "$*"; exit 1; }
WARNINGS=0

# ---- 0. checks before changing anything -------------------------------------
[ "$(id -u)" -eq 0 ] || fail "run it with sudo:   sudo bash $0"
STUDENT="${SUDO_USER:-}"
[ -n "$STUDENT" ] && [ "$STUDENT" != "root" ] || \
  fail "run it from your own account with sudo, not from a root shell."
STUDENT_HOME=$(getent passwd "$STUDENT" | cut -d: -f6)
STUDENT_UID=$(id -u "$STUDENT")
[ -d "$STUDENT_HOME" ] || fail "cannot find the home directory for $STUDENT."

. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || fail "this is ${PRETTY_NAME:-not Ubuntu}. The lab machine must be Ubuntu Server."
ARCH=$(uname -m)
case "$ARCH" in x86_64|aarch64) ;; *) fail "unsupported CPU architecture: $ARCH" ;; esac
HAVE_SYSTEMD=0; [ -d /run/systemd/system ] && HAVE_SYSTEMD=1

exec > >(tee -a "$LOG") 2>&1
echo "---- setup-lab-vm.sh $SCRIPT_VERSION  $(date -Is)  user=$STUDENT  $PRETTY_NAME  $ARCH"
[ "${VERSION_ID:-}" = "26.04" ] || warn "built for Ubuntu 26.04 — this is $VERSION_ID. Continuing — if anything fails, post on the Canvas discussion board."

# ---- 0b. use the whole virtual disk --------------------------------------------
# Ubuntu's installer gives the main partition only about half of the disk.
# Grow it (and its filesystem) to fill the disk. Costs nothing on the laptop:
# the VM's disk file only grows as space is actually used.
step "Checking the disk size"
ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null)
if command -v lvs >/dev/null && lvs "$ROOT_DEV" >/dev/null 2>&1; then
  VG=$(lvs --noheadings -o vg_name "$ROOT_DEV" | tr -d ' ')
  VG_FREE_MB=$(vgs --noheadings --units m --nosuffix -o vg_free "$VG" | tr -d ' ' | cut -d. -f1)
  if [ "${VG_FREE_MB:-0}" -gt 1024 ]; then
    if lvextend -q -r -l +100%FREE "$ROOT_DEV" >/dev/null 2>&1; then
      ok "main partition grown to fill the disk ($(df -h --output=size / | tail -1 | tr -d ' '))"
    else
      warn "could not grow the main partition — the labs still work, with less free space"
    fi
  else
    ok "main partition already uses the whole disk"
  fi
else
  ok "no change needed (main partition is not on LVM)"
fi

# ---- 1. full (not minimized) system: man pages are needed --------------------
step "Checking for a minimized install"
if [ -f /etc/dpkg/dpkg.cfg.d/excludes ] && command -v unminimize >/dev/null; then
  echo "    This is a minimized image (no man pages). Restoring — this takes a few minutes."
  yes | unminimize >/dev/null 2>&1 && ok "restored the full system" || warn "unminimize did not finish"
else
  ok "full install"
fi

# ---- 2. packages --------------------------------------------------------------
step "Installing packages (this can take 5–10 minutes the first time)"
export DEBIAN_FRONTEND=noninteractive
# If an earlier run (or update) was interrupted, finish it first.
dpkg --configure -a >/dev/null 2>&1 || true
apt-get update -qq || fail "apt-get update failed — check the machine's internet connection."
apt-get install -y -qq "${PACKAGES[@]}" >/dev/null || fail "package install failed — see $LOG"
ok "${#PACKAGES[@]} packages installed"
apt-get clean    # remove downloaded package files — saves disk space

# ---- 2b. keep the disk small --------------------------------------------------
# The installer may make a large swap file. 1 GB is enough for these labs.
if [ -f /swap.img ] && [ "$(stat -c %s /swap.img)" -gt $((1536*1024*1024)) ]; then
  if swapoff /swap.img 2>/dev/null; then
    rm -f /swap.img && fallocate -l 1G /swap.img && chmod 600 /swap.img \
      && mkswap -q /swap.img && swapon /swap.img \
      && ok "swap file reduced to 1 GB" || warn "could not recreate the swap file"
  else
    warn "could not resize the swap file (fine — it only uses more disk)"
  fi
fi
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "${FREE_GB:-0}" -ge 3 ] && ok "${FREE_GB} GB free on the VM's disk" \
  || warn "only ${FREE_GB} GB free on the VM's disk — the labs need about 3 GB free"

# ---- 3. machine identity and kernel settings ------------------------------------
step "Setting the machine name and kernel settings"
if [ "$(hostname)" != "$HOSTNAME_WANTED" ]; then
  if [ $HAVE_SYSTEMD -eq 1 ]; then hostnamectl set-hostname "$HOSTNAME_WANTED"; else hostname "$HOSTNAME_WANTED" 2>/dev/null; echo "$HOSTNAME_WANTED" > /etc/hostname; fi
fi
grep -q "[[:space:]]$HOSTNAME_WANTED\$" /etc/hosts || echo "127.0.1.1 $HOSTNAME_WANTED" >> /etc/hosts
# Cloud machines (Oracle, Azure) reset the name at every boot unless told not to.
if [ -d /etc/cloud/cloud.cfg.d ]; then
  echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-systems-software.cfg
fi
ok "machine name: $HOSTNAME_WANTED (your prompt changes after you log out and in)"
# The labs teach `sudo dmesg`, so keep Ubuntu's default restriction.
echo "kernel.dmesg_restrict = 1" > /etc/sysctl.d/99-systems-software.conf
sysctl -q -p /etc/sysctl.d/99-systems-software.conf 2>/dev/null || true
ok "dmesg needs sudo (as the labs expect)"

# ---- 4. rootless containers ---------------------------------------------------
step "Setting up containers for $STUDENT"
grep -q "^$STUDENT:" /etc/subuid || usermod --add-subuids 100000-165535 "$STUDENT"
grep -q "^$STUDENT:" /etc/subgid || usermod --add-subgids 100000-165535 "$STUDENT"
ok "user namespaces for $STUDENT"
# Let the student's containers use CPU and memory limits (containers lab).
mkdir -p /etc/systemd/system/user@.service.d
cat > /etc/systemd/system/user@.service.d/systems-software-delegate.conf <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
if [ $HAVE_SYSTEMD -eq 1 ]; then
  systemctl daemon-reload
  loginctl enable-linger "$STUDENT"
  ok "CPU and memory limits enabled for containers"
else
  warn "no systemd running here — container limits cannot be set up (fine for testing only)"
fi
# Pull the images the labs use, as the student (rootless images are per user).
RUN_AS=(runuser -u "$STUDENT" -- env HOME="$STUDENT_HOME" XDG_RUNTIME_DIR="/run/user/$STUDENT_UID")
for img in "${IMAGES[@]}"; do
  if "${RUN_AS[@]}" podman image exists "$img" 2>/dev/null; then
    ok "image $img already present"
  elif ( cd "$STUDENT_HOME" && "${RUN_AS[@]}" podman pull -q "$img" >/dev/null 2>&1 ); then
    ok "pulled $img"
  else
    warn "could not pull $img — check your internet connection and run the script again"
  fi
done

# ---- 5. lab files ---------------------------------------------------------------
step "Placing lab files in $STUDENT_HOME"
LAB3="$STUDENT_HOME/lab3"
install -d -o "$STUDENT" -g "$STUDENT" "$LAB3" "$LAB3/prebuilt"
# Only write a file if it is missing, so a student's own edits are never lost.
put() {  # put <path> ; content on stdin
  if [ -e "$1" ]; then cat >/dev/null; else cat > "$1"; chown "$STUDENT:$STUDENT" "$1"; fi
}
put "$LAB3/fib.py" <<'EOF'
"""Fibonacci, the slow recursive way — so there is plenty of work to time."""
import sys


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


n = int(sys.argv[1]) if len(sys.argv) > 1 else 30
print(f"fib({n}) = {fib(n)}")
EOF
put "$LAB3/fib.c" <<'EOF'
/* Fibonacci, the slow recursive way — the same algorithm as fib.py. */
#include <stdio.h>
#include <stdlib.h>

static long fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 30;
    printf("fib(%d) = %ld\n", n, fib(n));
    return 0;
}
EOF
put "$LAB3/Makefile" <<'EOF'
# `make fib_c` compiles fib.c into the program fib_c.
CFLAGS = -O2

fib_c: fib.c
	$(CC) $(CFLAGS) -o fib_c fib.c

clean:
	rm -f fib_c
EOF
# A ready-built copy, in case the compiler ever misbehaves on someone's machine.
if [ ! -x "$LAB3/prebuilt/fib_c" ]; then
  gcc -O2 -o "$LAB3/prebuilt/fib_c" "$LAB3/fib.c" && chown "$STUDENT:$STUDENT" "$LAB3/prebuilt/fib_c" \
    && ok "built prebuilt/fib_c for $ARCH" || warn "could not build prebuilt/fib_c"
fi
ok "lab files in ~/lab3"

# ---- 5b. lab tools (scenario scripts used in the labs) ---------------------------
# Kept in /opt/systems-software and REPLACED on every run, so a fix released
# by staff reaches students when they re-run this script. Students never edit
# these. Source: Labs/<lab>/lab-files/ — re-embed here after changing them.
TOOLS=/opt/systems-software
install -d -m 755 "$TOOLS"
cat > "$TOOLS/break-perms.sh" <<'LAB_TOOL_END'
#!/usr/bin/env bash
# Sets up the "report service" access fault for Core 3. Run with sudo.
# Safe to run more than once: it rebuilds the scenario from scratch.
#
# Correct design: /srv/reportapp root:reports 0750, config/ root:reports 0750,
# app.conf root:reports 0640, and reportsvc is in group reports.
# The ONE fault (default variant): config/ is 0700, so the group cannot pass
# through it. Set VARIANT=2 for a different single fault (app.conf is 0600).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
VARIANT="${VARIANT:-1}"

getent group reports >/dev/null || groupadd reports
id reportsvc >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin reportsvc
usermod -aG reports reportsvc

rm -rf /srv/reportapp
mkdir -p /srv/reportapp/config /srv/reportapp/data
printf 'port=8080\nreport_dir=/srv/reportapp/data\n' > /srv/reportapp/config/app.conf
chown -R root:reports /srv/reportapp
chmod 0750 /srv/reportapp /srv/reportapp/config /srv/reportapp/data
chmod 0640 /srv/reportapp/config/app.conf

case "$VARIANT" in
  1) chmod 0700 /srv/reportapp/config ;;
  2) chmod 0600 /srv/reportapp/config/app.conf ;;
  *) echo "unknown VARIANT"; exit 1 ;;
esac
echo "Scenario ready. Run: sudo bash /opt/systems-software/check-service.sh"
LAB_TOOL_END
cat > "$TOOLS/check-service.sh" <<'LAB_TOOL_END'
#!/usr/bin/env bash
# Can the report service read its configuration? Run with sudo.
if sudo -u reportsvc cat /srv/reportapp/config/app.conf >/dev/null 2>&1; then
  echo "OK: reportsvc can read /srv/reportapp/config/app.conf"
else
  echo "FAILED: reportsvc cannot read /srv/reportapp/config/app.conf"
  sudo -u reportsvc cat /srv/reportapp/config/app.conf 2>&1 | head -1
fi
LAB_TOOL_END
cat > "$TOOLS/break-mount.sh" <<'LAB_TOOL_END'
#!/usr/bin/env bash
# Sets up the Core 3 broken-mount scenario. Run with sudo.
#   sudo bash break-mount.sh            set up (default fault: wrong UUID)
#   VARIANT=2 sudo -E bash break-mount.sh   fault: mount point missing
#   VARIANT=3 sudo -E bash break-mount.sh   fault: wrong filesystem type
#   sudo bash break-mount.sh --remove   remove the scenario and its fstab line
#
# The fstab line always carries `nofail`, so a broken entry can never stop the
# VM from booting. Lines added by this script end with "# lab9" for removal.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
IMG=/var/lib/lab9/data.img

remove() {
  umount /srv/data 2>/dev/null || true
  for d in $(losetup -j "$IMG" 2>/dev/null | cut -d: -f1); do losetup -d "$d"; done
  sed -i '/# lab9$/d' /etc/fstab
  rm -rf /var/lib/lab9
  echo "Scenario removed."
}
if [ "${1:-}" = "--remove" ]; then remove; exit 0; fi
remove >/dev/null

mkdir -p /var/lib/lab9 /srv/data
truncate -s 64M "$IMG"
mkfs.ext4 -q "$IMG"
LOOP=$(losetup --find --show "$IMG")
TMP=$(mktemp -d); mount "$LOOP" "$TMP"; echo "hello from the data disk" > "$TMP/hello.txt"; umount "$TMP"; rmdir "$TMP"
UUID=$(blkid -s UUID -o value "$LOOP")

case "${VARIANT:-1}" in
  1) last="${UUID: -1}"; if [ "$last" = "0" ]; then BAD="${UUID%?}1"; else BAD="${UUID%?}0"; fi
     echo "UUID=$BAD /srv/data ext4 defaults,nofail 0 2 # lab9" >> /etc/fstab ;;
  2) rmdir /srv/data
     echo "UUID=$UUID /srv/data ext4 defaults,nofail 0 2 # lab9" >> /etc/fstab ;;
  3) echo "UUID=$UUID /srv/data xfs defaults,nofail 0 2 # lab9" >> /etc/fstab ;;
  *) echo "unknown VARIANT"; exit 1 ;;
esac
echo "Data disk is $LOOP. Scenario ready: the data disk should be mounted at /srv/data."
LAB_TOOL_END
chmod 755 "$TOOLS"/*.sh
ok "lab tools in $TOOLS"

# get-lab: downloads a lab's files into ~/labN (the automation lab needs the
# SimOS release inside the VM, and the VM has no shared folders or clipboard).
# It fetches labN.tar.gz if there is one; otherwise labN.tar.gz.enc, which it
# decrypts with a password the student types (released on Canvas). Staff make
# the .enc with Labs/setup/lock-lab.sh.
# Replaced on every run, like the tools above.
cat > /usr/local/bin/get-lab <<LAB_TOOL_END
#!/usr/bin/env bash
# get-lab N — put the files for lab N in ~/labN. Safe to run again: it never
# overwrites a file that is already there.
BASE="$LAB_FILES_URL"
LAB_TOOL_END
cat >> /usr/local/bin/get-lab <<'LAB_TOOL_END'
n="${1:-}"
case "$n" in
  ''|*[!0-9]*) echo "usage: get-lab <lab number>    (for example: get-lab 7)" >&2; exit 1 ;;
esac
dest="$HOME/lab$n"
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT
enc=$(mktemp) || exit 1
trap 'rm -f "$tmp" "$enc"' EXIT
if curl -fsSL "$BASE/lab$n.tar.gz" -o "$tmp" 2>/dev/null; then
  :   # an open release: no password
elif curl -fsSL "$BASE/lab$n.tar.gz.enc" -o "$enc" 2>/dev/null; then
  # A locked release: the password is on Canvas when the lab opens.
  ok=""
  for try in 1 2 3; do
    read -rsp "Password for lab $n (from Canvas): " pw; echo
    if printf '%s' "$pw" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
         -in "$enc" -out "$tmp" -pass stdin 2>/dev/null && tar -tzf "$tmp" >/dev/null 2>&1; then
      ok=1; break
    fi
    echo "That password did not work." >&2
  done
  [ -n "$ok" ] || { echo "Check the password on Canvas (it is case-sensitive) and try again." >&2; exit 1; }
else
  echo "Could not download the files for lab $n. Check that the machine is online," >&2
  echo "and that lab $n has been released (see Canvas)." >&2
  exit 1
fi
mkdir -p "$dest"
# --skip-old-files: a file that is already there (perhaps edited) is kept.
tar -xzf "$tmp" -C "$dest" --strip-components=1 --skip-old-files || { echo "The download for lab $n is damaged. Try again." >&2; exit 1; }
echo "The files for lab $n are in ~/lab$n"
LAB_TOOL_END
chmod 755 /usr/local/bin/get-lab
ok "get-lab installed"

# ---- 5c. lab container images (containers lab) -----------------------------------
# Two tiny images built from the ones pulled above, so students type a short
# `podman run` instead of a long quoted loop. Their source stays readable in
# /opt/systems-software/images/ — the lab points students there.
step "Building the lab container images"
IMGSRC="$TOOLS/images"
mkdir -p "$IMGSRC/busy" "$IMGSRC/memtest"
cat > "$IMGSRC/busy/busy.sh" <<'LAB_IMG_END'
#!/bin/sh
# busy - the CPU test for the containers lab.
# It only counts, so the only thing that changes its speed is how much
# CPU time the kernel lets this container have.
# Usage: busy [COUNT]   (default 1000000; use the same COUNT for every run)
N=${1:-1000000}
case "$N" in
  ''|*[!0-9]*) echo "busy: COUNT must be a whole number, e.g.  podman run --rm busy 3000000"; exit 2 ;;
esac

# The container's CPU limit, as the kernel's cgroup sees it.
limit="no limit"
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max
  if [ "$quota" != "max" ]; then
    limit=$(awk -v q="$quota" -v p="$period" 'BEGIN { printf "%.2f CPU", q / p }')
    limit="$limit (cpu.max: may run $quota of every $period microseconds)"
  fi
fi
echo "busy: CPU limit: $limit"
echo "busy: counting to $N ..."

start=$(cut -d' ' -f1 /proc/uptime)
i=0
while [ "$i" -lt "$N" ]; do i=$((i + 1)); done
end=$(cut -d' ' -f1 /proc/uptime)

awk -v s="$start" -v e="$end" 'BEGIN { printf "busy: took %.2f seconds\n", e - s }'
LAB_IMG_END
cat > "$IMGSRC/busy/Containerfile" <<'LAB_IMG_END'
FROM docker.io/library/alpine
COPY busy.sh /busy.sh
ENTRYPOINT ["/bin/sh", "/busy.sh"]
LAB_IMG_END
cat > "$IMGSRC/memtest/memtest.py" <<'LAB_IMG_END'
"""memtest - the memory test for the containers lab.

Usage: memtest <MB>   asks for that many megabytes, then fills them.
"""
import sys

mb = int(sys.argv[1]) if len(sys.argv) > 1 else 64

# The container's memory limit, as the kernel's cgroup sees it.
try:
    raw = open("/sys/fs/cgroup/memory.max").read().strip()
    limit = "no limit" if raw == "max" else f"{int(raw) // (1024 * 1024)} MB"
except OSError:
    limit = "unknown"
print(f"memtest: memory limit: {limit}")
print(f"memtest: asking for {mb} MB ...")
print("memtest: (if the kernel kills me for going over the limit, nothing more")
print("          is printed - run  echo $?  and look for 137)", flush=True)

data = b"\xff" * (mb * 1024 * 1024)  # every byte written, so it really uses the memory

print(f"memtest: got all {mb} MB - it fit within the limit.")
LAB_IMG_END
cat > "$IMGSRC/memtest/Containerfile" <<'LAB_IMG_END'
FROM docker.io/library/python:3-slim
COPY memtest.py /memtest.py
ENTRYPOINT ["python3", "/memtest.py"]
LAB_IMG_END
chmod -R a+rX "$IMGSRC"
for name in busy memtest; do
  if ( cd /tmp && "${RUN_AS[@]}" podman build -q --pull=never -t "localhost/$name" "$IMGSRC/$name" >/dev/null 2>&1 ); then
    ok "image $name"
  else
    warn "could not build image $name — run the script again once the image pulls above succeed"
  fi
done

echo "$SCRIPT_VERSION $(date -Is)" > /etc/systems-software-lab-version

# Hand freed disk space back to the laptop, where the VM tool allows it.
fstrim -a >/dev/null 2>&1 || true

# ---- 6. check the result ----------------------------------------------------------
step "Checking the result"
MISSING=0
for t in man nano less python3 pytest gcc make /usr/bin/time size file ldd xxd get-lab openssl \
         lscpu ps top free strace lsof ss setfacl getfacl namei losetup findmnt \
         blkid mkfs.ext4 podman; do
  command -v "$t" >/dev/null || { warn "missing: $t"; MISSING=1; }
done
[ $MISSING -eq 0 ] && ok "all lab commands present"
man -w 2 open >/dev/null 2>&1 && ok "system-call manual pages (man 2 open)" || warn "man 2 open does not work — run: sudo apt install manpages-dev"
dmesg >/dev/null 2>&1 && ok "sudo dmesg works" || warn "dmesg does not work"
TIME_OUT=$(/usr/bin/time -v true 2>&1)
case "$TIME_OUT" in *"Maximum resident"*) ok "/usr/bin/time -v works" ;; *) warn "/usr/bin/time -v does not work" ;; esac
( cd /tmp && runuser -u "$STUDENT" -- make -s -C "$LAB3" fib_c >/dev/null 2>&1 && "$LAB3/fib_c" 10 >/dev/null ) \
  && ok "compiler works (make fib_c)" || warn "make fib_c failed"
for name in busy memtest; do
  "${RUN_AS[@]}" podman image exists "localhost/$name" 2>/dev/null || { warn "missing container image: $name"; MISSING=1; }
done
CPUS=$(nproc)
[ "$CPUS" -ge 2 ] && ok "$CPUS CPUs" || warn "this machine has $CPUS CPU — the labs expect 2. Local VM: set 2 CPUs in its settings. Cloud: choose a 2-CPU size."

printf '\n'
if [ $WARNINGS -eq 0 ]; then
  echo "DONE — your lab machine is ready. Log out and log back in (type: exit)."
else
  echo "DONE WITH $WARNINGS WARNING(S) — read the WARN lines above. Most say what to do."
  echo "If you cannot fix them: search the warning text or ask an AI tool, then post a"
  echo "screenshot on the Canvas discussion board. A full log is in $LOG"
fi
