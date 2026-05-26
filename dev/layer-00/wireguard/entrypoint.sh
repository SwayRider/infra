#!/bin/sh
if [ -z "$PASSWORD_HASH" ] && [ -n "$WG_PASSWORD" ]; then
  export PASSWORD_HASH=$(wgpw "$WG_PASSWORD" | sed 's/Password hash: //')
fi

# Forward all TCP from VPN clients to the Docker host so any published port
# is reachable via 10.8.0.1. Scoped to 10.8.0.0/24 so container-internal
# traffic is unaffected. wg-easy's own MASQUERADE rule handles the return path.
GW=$(ip route | awk '/^default/ { print $3 }')
iptables -t nat -A PREROUTING -s 10.8.0.0/24 -p tcp -j DNAT --to-destination "$GW"

exec "$@"
