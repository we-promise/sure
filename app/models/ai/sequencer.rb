# The lane an AI call runs in: interactive, prompt or background (Ai::Routes::MATRIX), and the
# gate of each local model host, where the lanes take turns (Ai::Gate). A job takes its queue's
# lane (ApplicationJob); evals and the console choose one with `with_lane`.
#
# The lane is fiber storage, like Ai::CallContext and Ai::Capsule's mark, so threads a job starts
# (Jev's parallel requests) run in the job's lane.
module Ai::Sequencer
  LANES = %i[interactive prompt background].freeze
  # How long a gate's size stands before its host is asked again.
  RESIZE_AFTER = 10.minutes
  PROPS_TIMEOUT = 2

  # A host's gate, and the slots each of its servers (one per port) last reported.
  Sized = Struct.new(:gate, :servers)
  Server = Struct.new(:slots, :at)
  GATES = Concurrent::Map.new

  class << self
    # Whether a gate asks its host for its slots. Off in tests, which make no unplanned requests.
    attr_accessor :ask_servers
  end
  self.ask_servers = true

  module_function

  # A call outside any lane (a test, the console) counts as interactive, so nothing makes it wait
  # for work that would never come back for it.
  def lane = Fiber[:ai_lane] || :interactive

  # Runs the block in `lane`; nil leaves the current lane as it is.
  def with_lane(lane)
    return yield if lane.nil?
    raise ArgumentError, "unknown lane: #{lane.inspect}" unless LANES.include?(lane)

    begin
      previous = Fiber[:ai_lane]
      Fiber[:ai_lane] = lane
      yield
    ensure
      Fiber[:ai_lane] = previous
    end
  end

  # The check a request makes once it has a place at a gate, before it's sent (§12's cancel
  # point): when it answers true, the request raises Ai::Error::Cancelled instead.
  def cancelled = Fiber[:ai_cancelled]

  def cancellable(check)
    return yield if check.nil?

    begin
      previous = Fiber[:ai_cancelled]
      Fiber[:ai_cancelled] = check
      yield
    ensure
      Fiber[:ai_cancelled] = previous
    end
  end

  # The gate of a local endpoint's host, shared by every endpoint on that host, or nil for a cloud
  # endpoint, which has none. Servers on one host's ports (a chat model and an embedding model, say)
  # share its GPU, so they share one gate, as many places as the smallest of them has slots. Each
  # server is asked for its slots when first seen and again after RESIZE_AFTER.
  def gate_for(endpoint)
    return unless endpoint.local?

    sized = GATES[host_key(endpoint)]
    server = sized&.servers&.[](server_key(endpoint))
    return sized.gate if server && now - server.at <= RESIZE_AFTER

    server.at = now if server # one thread asks again; the others keep the current size meanwhile
    resize(endpoint, sized)
  end

  # Asked outside the map's lock, which compute_if_absent would hold for every host meanwhile.
  def resize(endpoint, sized)
    server = Server.new(slots(endpoint), now)
    sized ||= begin
      fresh = Sized.new(Ai::Gate.new(server.slots), Concurrent::Map.new)
      GATES.put_if_absent(host_key(endpoint), fresh) || fresh
    end
    sized.servers[server_key(endpoint)] = server
    sized.gate.size = sized.servers.values.map(&:slots).min
    sized.gate
  end

  # llama.cpp's `total_slots`, or else the endpoint's parallel_requests, or 1.
  def slots(endpoint) = (server_slots(endpoint) if ask_servers) || endpoint.parallel_requests || 1

  # llama.cpp answers GET /props with its slots; any other server has no such page. Through
  # Ai::Transport::Http, so the proxy setting applies. Not a model call, so it holds no place.
  def server_slots(endpoint)
    base = Ai::Transport::Http.compatible_base(endpoint.base_url).delete_suffix("/v1")
    headers = Ai::Transport::Http.headers(endpoint)
    headers = headers.merge("Authorization" => "Bearer #{endpoint.api_key}") if endpoint.api_key
    response = Ai::Transport::Http.faraday(base, timeout: PROPS_TIMEOUT).get("#{base}/props", nil, headers)
    slots = JSON.parse(response.body)["total_slots"] if response.success?
    slots if slots.is_a?(Integer) && slots.positive?
  rescue StandardError
    nil
  end

  def host_key(endpoint) = parsed_base_url(endpoint)&.host&.downcase || endpoint.name

  def server_key(endpoint)
    uri = parsed_base_url(endpoint)
    uri&.host ? "#{uri.host.downcase}:#{uri.port}" : endpoint.name
  end

  def parsed_base_url(endpoint)
    URI.parse(endpoint.base_url.to_s)
  rescue URI::InvalidURIError
    nil
  end

  # Tests start each case without the gates an earlier one sized.
  def forget_gates = GATES.clear

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
