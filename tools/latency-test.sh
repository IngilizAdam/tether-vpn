#!/bin/bash
# Measure how much latency the tunnel adds.
#
# Usage: tools/latency-test.sh [PHONE_IP:PORT]
#
# Pings the phone, then times HTTPS requests through the system-wide tunnel.
# If you pass the proxy address, it also times the same requests sent straight
# to the SOCKS proxy (skipping tun2socks) so you can compare the two.
#
# Median of N runs: TLS handshake done (time_appconnect) and first byte (time_starttransfer), in ms
m() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
run() { # label, extra curl args..., url last
  local label=$1; shift; local tls=() ttfb=()
  for i in $(seq 7); do
    read a s < <(curl -s -o /dev/null --max-time 10 -w '%{time_appconnect} %{time_starttransfer}\n' "$@")
    tls+=($(awk "BEGIN{print int($a*1000)}")); ttfb+=($(awk "BEGIN{print int($s*1000)}"))
  done
  printf '%-34s TLS %5s ms   first-byte %5s ms\n' "$label" "$(printf '%s\n' "${tls[@]}"|m)" "$(printf '%s\n' "${ttfb[@]}"|m)"
}
GW=$(ip -4 route show default | awk '/via/{print $3;exit}')
echo "Link to phone ($GW):"; ping -c 10 -i 0.2 -q "$GW" | tail -1
for u in https://1.1.1.1/cdn-cgi/trace https://www.google.com/generate_204; do
  run "system-wide  $(echo $u|cut -d/ -f3)" "$u"
  [[ -n $1 ]] && run "direct socks $(echo $u|cut -d/ -f3)" --socks5 "$1" --noproxy '' "$u"
done
