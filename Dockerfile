# ── Stage 1: Builder ────────────────────────────────────────────────────────
# Compila aegis_core (Rust/Cargo via Rustler) + release Phoenix OTP
FROM hexpm/elixir:1.16.3-erlang-26.2.5-debian-bullseye-20240701-slim AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"
ENV MIX_ENV=prod

WORKDIR /app

# Deps Elixir — cached em layer separada
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod

# Código-fonte completo (inclui native/ para Cargo)
COPY . .

# Rustler invoca `cargo build --release` automaticamente durante mix compile
RUN mix compile

# Gera release OTP
RUN mix release

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
# Imagem final: somente runtime Debian + release OTP + NIFs .so (~100–150 MB)
FROM debian:bullseye-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

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
