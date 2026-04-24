#!/bin/sh
if [ -z "$PASSWORD_HASH" ] && [ -n "$WG_PASSWORD" ]; then
  export PASSWORD_HASH=$(wgpw "$WG_PASSWORD" | sed 's/Password hash: //')
fi
exec "$@"
