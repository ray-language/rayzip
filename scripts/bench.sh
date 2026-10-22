#!/bin/sh
# rayzip against the system's zip, unzip and gzip: time and peak memory (macOS /usr/bin/time -l
# or GNU time -v). The corpus is generated under $BENCH_DIR (default: a temporary directory)
# and removed at the end.
set -eu

RZ="$(cd "$(dirname "$0")/.." && pwd)/rayzip"
DIR="$(mktemp -d "${BENCH_DIR:-${TMPDIR:-/tmp}}/rayzip-bench.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

measure() {
    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/real/{r=$1} /maximum resident/{printf "%7.2f s %6d MB", r, $1/1048576}'
    else
        /usr/bin/time -v "$@" 2>&1 >/dev/null | awk -F': ' '/Elapsed/{split($2,t,":"); r=t[1]*60+t[2]} /Maximum resident/{m=$2} END{printf "%7.2f s %6d MB", r, m/1024}'
    fi
}

# 256 MiB of text, and the same cut into 1 MB files. A word list compresses like prose (about
# 3.3:1), so the 256 MiB file deflates to more than 64 MiB and its readers take the streaming
# path; generated rows would compress far better and stay on the one-call path.
if [ -r /usr/share/dict/words ]; then
    cp /usr/share/dict/words base.txt
else
    i=0
    while [ $i -lt 300000 ]; do echo "w$((i * 7919 % 1000003))x$((i * 104729 % 65521))"; i=$((i + 1)); done > base.txt
fi
: > big.txt
while [ "$(wc -c < big.txt)" -lt 268435456 ]; do cat base.txt >> big.txt; done
head -c 268435456 big.txt > big.tmp && mv big.tmp big.txt
mkdir many && head -c 25000000 big.txt | (cd many && split -b 1000000 - part-)

echo "== 25 files of 1 MB"
for j in 1 2 4 8; do
    echo "$(measure "$RZ" c "p$j.zip" many -q -j $j)  rayzip c -j $j"
done
echo "$(measure zip -qr pz.zip many)  zip -r"

echo "== one file of 256 MiB"
echo "$(measure "$RZ" c b1.zip big.txt -q)  rayzip c (deflated in chunks)"
echo "$(measure "$RZ" c b2.zip big.txt -q --max-deflate 1G)  rayzip c --max-deflate 1G (deflated whole, in memory)"
echo "$(measure "$RZ" c b3.zip big.txt -q -0)  rayzip c -0 (stored, in chunks)"
echo "$(measure zip -q bz.zip big.txt)  zip"
echo "$(measure "$RZ" t b1.zip -q)  rayzip t"
echo "$(measure unzip -tq b1.zip)  unzip -t"
echo "$(measure "$RZ" gzip big.txt -c big.gz -q)  rayzip gzip"
echo "$(measure sh -c 'gzip -c big.txt > bigg.gz')  gzip"
echo "$(measure "$RZ" gunzip big.gz -c big.out -q)  rayzip gunzip (its own members)"
echo "$(measure "$RZ" gunzip bigg.gz -c bigg.out -q)  rayzip gunzip (gzip's single member)"
echo "$(measure sh -c 'gzip -dc bigg.gz > /dev/null')  gzip -d"
cmp big.out big.txt && cmp bigg.out big.txt && echo "round trips identical"
echo "compressed: $(wc -c < b1.zip) (rayzip zip, chunks), $(wc -c < b2.zip) (rayzip zip, whole), $(wc -c < bz.zip) (zip), $(wc -c < big.gz) (rayzip gzip), $(wc -c < bigg.gz) (gzip)"
