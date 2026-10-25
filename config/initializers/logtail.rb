# Rails already logs requests with filtered parameters. Logtail's HTTP events
# separately serialize raw headers (including credentials and cookies) and query
# strings, bypassing Rails' filters. Disable them before Logtail's Railtie builds
# the middleware stack, regardless of whether remote logging is configured.
# The Logtail logger remains available as a destination for normal Rails logs.
Logtail::Integrations::Rack::HTTPEvents.enabled = false
