# ── Stage 1: Builder ────────────────────────────────────────────────────────
# Compila aegis_core (Rust/Cargo via Rustler) + release Phoenix OTP
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bookworm-20241202-slim AS builder

# hadolint ignore=DL3008
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      build-essential \
      git \
      curl && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"
ENV MIX_ENV=prod

WORKDIR /app

# Deps Elixir — cached em layer separada
# Usa glob (mix.lock*) para tolerar ausência do lockfile em repos novos.
# IMPORTANTE: commite o mix.lock gerado por `mix deps.get` para builds
# reproduzíveis e para ativar o cache de layer corretamente.
COPY mix.exs mix.lock* ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

# Código-fonte completo (inclui native/ para Cargo)
COPY . .

# Rustler invoca `cargo build --release` automaticamente durante mix compile
# Gera release OTP em seguida
RUN mix compile && \
    mix release

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
# Imagem final: somente runtime Debian + release OTP + NIFs .so (~100–150 MB)
FROM debian:bookworm-slim AS runtime

# hadolint ignore=DL3008
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Copia apenas o release (NIFs .so embutidos via Rustler)
COPY --from=builder /app/_build/prod/rel/uncover_aegis ./

# Usuário não-root (segurança)
RUN useradd -m -u 1001 aegis && chown -R aegis:aegis /app
USER aegis

EXPOSE 4000

ENV PHX_HOST=localhost
ENV PORT=4000
ENV SECRET_KEY_BASE=""
ENV DATABASE_PATH="/app/data/uncover_aegis.db"
ENV REDIS_HOST="localhost"

CMD ["/app/bin/uncover_aegis", "start"]
