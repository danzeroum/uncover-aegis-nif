import Config

# Configura a crate Rust compilada pelo Rustler.
# Em :prod usa :release para otimizações máximas do compilador Rust (LTO, opt-level 3).
# Em :dev/:test usa :debug para compilação mais rápida.
config :uncover_aegis, UncoverAegis.Native,
  crate: :aegis_core,
  mode: if(Mix.env() == :prod, do: :release, else: :debug)
