import Config

# If running in standalone agent mode, this is where your
# config can go

configurator =
  case System.get_env("NH_CONFIGURATOR") do
    nil ->
      NervesHubLink.Configurator.SharedSecret

    "SharedSecret" ->
      NervesHubLink.Configurator.SharedSecret

    "NervesKey" ->
      NervesHubLink.Configurator.NervesKey
  end

config :nerves_hub_link,
  host: System.fetch_env!("NH_HOST"),
  configurator: configurator

if configurator == NervesHubLink.Configurator.SharedSecret do
  config :nerves_hub_link,
    shared_secret: [
      product_key: System.fetch_env!("NH_PRODUCT_KEY"),
      product_secret: System.fetch_env!("NH_PRODUCT_SECRET")
    ]
end
