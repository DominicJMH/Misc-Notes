defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_app,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {MyApp.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Rustler provides the `use Rustler` macro and manages NIF loading.
      # The actual Rust compilation (via cargo) happens during `mix compile`
      # unless skip_compilation?: true is set, which we control via
      # the PRECOMPILED_NIF environment variable at compile time.
      {:rustler, "~> 0.30"}
    ]
  end
end
