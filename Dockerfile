FROM hexpm/elixir:1.17.3-erlang-27.3.4.12-debian-bookworm-20260610-slim AS build

WORKDIR /app
ENV MIX_ENV=prod HOME=/app/.build/home MIX_HOME=/app/.build/mix HEX_HOME=/app/.build/hex TMPDIR=/app/.build/tmp MAKEFLAGS=-j2 ERL_AFLAGS="+S 2:2"
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN mkdir -p "$HOME" "$MIX_HOME" "$HEX_HOME" "$TMPDIR" && mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock .formatter.exs ./
RUN mix deps.get --only prod
COPY LICENSE ./
COPY config ./config
COPY lib ./lib
COPY priv ./priv
COPY assets ./assets
RUN mix release && rm -f /app/_build/prod/rel/arena/releases/COOKIE \
    && mkdir -p /app/third_party_licenses \
    && for dep in /app/deps/*; do \
      for notice in "$dep"/LICENSE* "$dep"/LICENCE* "$dep"/NOTICE* "$dep"/COPYING*; do \
        if [ -f "$notice" ]; then mkdir -p "/app/third_party_licenses/$(basename "$dep")" && cp "$notice" "/app/third_party_licenses/$(basename "$dep")/"; fi; \
      done; \
    done

FROM debian:bookworm-20260610-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl hostname && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=nobody:nogroup /app/_build/prod/rel/arena/ ./
COPY --from=build /app/LICENSE /app/LICENSE
COPY --from=build /app/third_party_licenses/ /app/third_party_licenses/
COPY --chown=nobody:nogroup scripts/container_entrypoint.sh /app/bin/cluster-entrypoint
RUN mkdir -p /app/.runtime/home /app/.runtime/tmp && chown -R nobody:nogroup /app/.runtime && chmod 0555 /app/bin/cluster-entrypoint
ENV HOME=/app/.runtime/home TMPDIR=/app/.runtime/tmp ERL_CRASH_DUMP=/app/.runtime/erl_crash.dump
USER nobody
ENTRYPOINT ["/app/bin/cluster-entrypoint"]
CMD ["start"]
