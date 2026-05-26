#!/bin/sh
if [ -z "$PASSWORD_HASH" ] && [ -n "$WG_PASSWORD" ]; then
  eval "$(wgpw "$WG_PASSWORD")"
  export PASSWORD_HASH
fi
exec "$@"
