#!/usr/bin/env bash
#
# package.sh - turn a finished build into an installable tarball.
#
#   bash scripts/package.sh --prefix /opt/couchbase --version 8.0.3-9999 \
#                           --edition enterprise --output ./packages
#
# Produces, in the output directory:
#   couchbase-server-<edition>_<version>-linux_s390x.tar.gz    the install tree
#   couchbase-server-<edition>_<version>-linux_s390x.sha256    its checksum
#   install-couchbase-server-s390x.sh                           installs it on a target host
#
# Notes
#  * A Couchbase install tree is tied to the prefix it was built with (start
#    scripts and the Erlang runtime contain absolute paths), so a package is
#    only useful for other machines when the build used a stable prefix such
#    as /opt/couchbase (build_couchbase_ee.sh --prefix /opt/couchbase).
#  * The target must run the same distribution release as the build host: the
#    binaries are linked against that distribution's glibc and system
#    libraries, including the runtime of the compiler the build installed
#    (GCC 13 or 14). The installer lists any library the target lacks.
#  * This is not Couchbase's official RPM/DEB packaging (that lives in the
#    private "voltron" project). The installer below does the equivalent
#    minimum: a 'couchbase' user, file ownership and a systemd unit.
#
set -euo pipefail

PREFIX=""
VERSION="8.0.3-9999"
EDITION="enterprise"
OUTPUT="$(pwd)/packages"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)  PREFIX="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --edition) EDITION="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$PREFIX" ] || { echo "ERROR: --prefix is required" >&2; exit 1; }
PREFIX="$(cd "$PREFIX" && pwd)"
[ -x "$PREFIX/bin/couchbase-server" ] || { echo "ERROR: $PREFIX/bin/couchbase-server not found - is this a finished build?" >&2; exit 1; }

ARCH="$(uname -m)"
NAME="couchbase-server-${EDITION}_${VERSION}-linux_${ARCH}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

if [ "$PREFIX" != "/opt/couchbase" ]; then
    echo "WARNING: this build's prefix is $PREFIX, not /opt/couchbase."
    echo "         The package will only work when installed at exactly $PREFIX."
fi

echo "Checking that the shipped binaries find their libraries..."
# Anything "not found" here would also be missing on the target host.
unresolved=""
while IFS= read -r -d '' binary; do
    if file -b "$binary" | grep -q '^ELF'; then
        if missing="$(ldd "$binary" 2>/dev/null | grep 'not found')"; then
            unresolved="${unresolved}${binary}:
${missing}
"
        fi
    fi
done < <(find "$PREFIX/bin" -maxdepth 1 -type f -print0)
if [ -n "$unresolved" ]; then
    echo "WARNING: unresolved shared libraries:"
    echo "$unresolved"
fi

# Record what the package was built from and on.
{
    echo "Couchbase Server ${VERSION} (${EDITION}) for linux/${ARCH}"
    echo "Unofficial from-source build; not a Couchbase release binary."
    echo "Built:  $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(. /etc/os-release && echo "$PRETTY_NAME"), glibc $(ldd --version | head -1 | awk '{print $NF}')"
    echo "Prefix: ${PREFIX}"
} > "$PREFIX/S390X-BUILD-INFO.txt"

echo "Creating $OUTPUT/$NAME.tar.gz ..."
# Runtime state (data, logs, node config) is not part of a package.
tar --numeric-owner --owner=0 --group=0 \
    --exclude="${PREFIX#/}/var/lib/couchbase/*" \
    -C / -czf "$OUTPUT/$NAME.tar.gz" "${PREFIX#/}"
( cd "$OUTPUT" && sha256sum "$NAME.tar.gz" > "$NAME.sha256" )

cat > "$OUTPUT/install-couchbase-server-s390x.sh" <<EOF
#!/usr/bin/env bash
# Installs $NAME.tar.gz on this host. Run as root, from the directory
# that contains the tarball:   sudo bash install-couchbase-server-s390x.sh
set -euo pipefail
PREFIX="$PREFIX"
TARBALL="\$(cd "\$(dirname "\$0")" && pwd)/$NAME.tar.gz"

[ "\$(id -u)" = "0" ] || { echo "run this script as root (sudo)" >&2; exit 1; }
[ "\$(uname -m)" = "$ARCH" ] || { echo "this package is for $ARCH" >&2; exit 1; }
[ -f "\$TARBALL" ] || { echo "\$TARBALL not found" >&2; exit 1; }
if [ -e "\$PREFIX/bin/couchbase-server" ]; then
    echo "\$PREFIX already contains a Couchbase Server installation; remove or move it first" >&2
    exit 1
fi
( cd "\$(dirname "\$TARBALL")" && sha256sum -c "$NAME.sha256" )

getent group couchbase >/dev/null || groupadd -r couchbase
getent passwd couchbase >/dev/null || useradd -r -g couchbase -d "\$PREFIX" -s /sbin/nologin -c "Couchbase Server" couchbase

tar -C / -xzf "\$TARBALL"
mkdir -p "\$PREFIX/var/lib/couchbase"
chown -R couchbase:couchbase "\$PREFIX"

# The binaries are linked against the build host's system libraries (the
# compiler's runtime included). Report any that this host does not have.
missing="\$(for f in "\$PREFIX"/bin/*; do
    [ -f "\$f" ] && ldd "\$f" 2>&1 | grep 'not found' | sed "s|^[[:space:]]*|    \$(basename "\$f"): |"
done | sort -u | head -40 || true)"
if [ -n "\$missing" ]; then
    echo
    echo "WARNING: this host lacks shared libraries the server needs:"
    echo "\$missing"
    echo "Install the packages that provide them (the build host has them) before"
    echo "starting the server."
fi

echo
echo "Installed to \$PREFIX. Couchbase recommends disabling Transparent Huge Pages"
echo "and setting vm.swappiness=1 before starting the server."

# A systemd unit where systemd is running; otherwise (for example in a
# container) say how to start the server by hand.
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/couchbase-server.service <<UNIT
# Written by install-couchbase-server-s390x.sh (unofficial s390x build).
[Unit]
Description=Couchbase Server
Documentation=https://docs.couchbase.com
After=network-online.target
Wants=network-online.target

[Service]
User=couchbase
Group=couchbase
# "couchbase-server --start" detaches and writes the pid file; "--stop" sends
# the babysitter SIGTERM and waits for a clean shutdown.
Type=forking
PIDFile=\$PREFIX/var/lib/couchbase/couchbase-server.pid
WorkingDirectory=\$PREFIX/var/lib/couchbase
ExecStart=\$PREFIX/bin/couchbase-server --start
ExecStop=\$PREFIX/bin/couchbase-server --stop
LimitNOFILE=200000
LimitNPROC=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity
TasksMax=infinity
TimeoutStartSec=120
TimeoutStopSec=180
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    echo "Start it with:   systemctl enable --now couchbase-server"
else
    echo "systemd is not running here, so no service unit was installed."
    echo "Start it with:   su -s /bin/sh couchbase -c '\$PREFIX/bin/couchbase-server --start'"
    echo "(the couchbase user needs 'ulimit -n 200000' or more)"
fi
echo "Then open:       http://\$(hostname -f 2>/dev/null || hostname):8091"
EOF
chmod 0755 "$OUTPUT/install-couchbase-server-s390x.sh"

echo
echo "Package:   $OUTPUT/$NAME.tar.gz ($(du -h "$OUTPUT/$NAME.tar.gz" | cut -f1))"
echo "Checksum:  $OUTPUT/$NAME.sha256"
echo "Installer: $OUTPUT/install-couchbase-server-s390x.sh"
