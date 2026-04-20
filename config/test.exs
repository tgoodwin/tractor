import Config

# In test, the endpoint is started explicitly via TractorWeb.Server in the
# RunLive tests. Keep it off by default so other tests don't open a listener.
config :tractor, TractorWeb.Endpoint, server: false
