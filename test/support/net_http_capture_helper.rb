# frozen_string_literal: true

# Proxy assertions for clients that open their own Net::HTTP connection.
module NetHttpCaptureHelper
  PROXY = "http://proxy.internal:8888"

  # Stubs Net::HTTP.new to record its arguments -- host, port, then the proxy's host, port,
  # user and password -- and hand back a real connection to host:port, so WebMock still
  # answers the request. A client that leaves the proxy to Net::HTTP's own ENV lookup
  # passes :ENV as the proxy host. Returns [calls, connection].
  def capture_net_http_new(host, port)
    calls = []
    connection = Net::HTTP.newobj(host, port)
    Net::HTTP.stubs(:new).with { |*args| calls << args }.returns(connection)
    [ calls, connection ]
  end

  # Sets every proxy variable, upper and lower case, so the machine running the tests
  # cannot leak its own.
  def with_proxy_env(https: nil, http: nil, no_proxy: nil, &block)
    with_env_overrides(
      "HTTPS_PROXY" => https, "https_proxy" => nil, "HTTP_PROXY" => http, "http_proxy" => nil,
      "NO_PROXY" => no_proxy, "no_proxy" => nil, &block
    )
  end
end
