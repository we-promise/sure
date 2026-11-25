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

  Sized = Struct.new(:gate, :at)
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

  # The gate of a local endpoint's host, shared by every endpoint on that host and port, or nil
  # for a cloud endpoint, which has none. Sized by the host's slots, asked again after RESIZE_AFTER.
  def gate_for(endpoint)
    return unless endpoint.local?

    key = host_key(endpoint)
    # Asked outside the map's lock, which compute_if_absent would hold for every host meanwhile.
    sized = GATES[key] || begin
      fresh = Sized.new(Ai::Gate.new(slots(endpoint), host: key), now)
      GATES.put_if_absent(key, fresh) || fresh
    end
    if now - sized.at > RESIZE_AFTER
      sized.at = now
      sized.gate.size = slots(endpoint)
    end
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

  def host_key(endpoint)
    uri = URI.parse(endpoint.base_url.to_s)
    uri.host ? "#{uri.host}:#{uri.port}" : endpoint.name
  rescue URI::InvalidURIError
    endpoint.name
  end

  # The local endpoint a user's chat route uses, whose gate chat takes and whose host the typing
  # hold keeps free. Nil for a cloud model, an external assistant (it calls its own models) or no chat.
  def chat_endpoint(user)
    endpoint = chat_route(user)&.endpoint
    endpoint if endpoint&.local? && !endpoint.agent?
  end

  def external_chat?(user) = chat_route(user)&.agent? || false

  def chat_route(user) = user && Ai.plan(:chat, family: user.family, user:)&.route

  def local_endpoints = Ai::Config.current.endpoints.select { _1.local? && !_1.agent? }

  # Runs an external assistant's turn with no new background request starting on this worker's local
  # hosts, one of which may serve the assistant's own models: its calls don't pass a gate. The
  # message has been sent, so it ends the typing hold. The turn holds no place, so a tool it calls
  # in Sure never waits for it.
  def external_chat(user)
    gates = local_endpoints.filter_map { gate_for(_1) }.uniq
    gates.each(&:hold_off_background)
    ChatReservation.release(local_endpoints, user:)
    yield
  ensure
    gates&.each(&:let_background_in)
  end

  # Temporary, until chat's requests pass Ai::Transport::Instrumenter like every other one's: runs a
  # chat request holding a place at its model host's gate. The message has been sent, so it ends
  # the typing hold. Around one request, never a turn, so a tool's own AI call can have the place.
  # `on_place` gets the seconds the request waited for it; the reply counts as waiting until it returns.
  def hold_for_chat(endpoint, user:, reply:, on_place:)
    if endpoint.nil?
      on_place.call(0)
      return yield
    end

    gate_for(endpoint).hold(:interactive, feature: "chat", job: reply, on_place:) do
      ChatReservation.release([ endpoint ], user:)
      yield
    end
  end

  # Refreshes the published state of each gate in use before it expires (Ai::Gate::State::TTL).
  def publish_gates = GATES.each_value { |sized| sized.gate.publish if sized.gate.in_use? }

  # Tests start each case without the gates an earlier one sized.
  def forget_gates = GATES.clear

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
