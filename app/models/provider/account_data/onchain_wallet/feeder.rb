require "base64"

class Provider::AccountData::OnchainWallet::Feeder
  Archive = Provider::AccountData::OnchainWallet::CaptureArchive

  def initialize(client:, sources:, configuration:, capture:, observed_at:, timezone:, sync_start_date:, keyed_history:)
    @client, @scope = client, capture.fetch("scope")
    @fragments = []
    raise ArgumentError unless @scope.fetch("observed_at") == observed_at.getutc.iso8601(9)
    @input_digest = Archive.digest({ "sources" => sources.map { |source| source[:external].slice(:id, :external_id, :identity_namespace, :currency).merge(descriptor: source[:descriptor]) },
      "configuration" => configuration, "keyed_history" => keyed_history, "timezone" => timezone, "sync_start_date" => sync_start_date&.iso8601 })
    raise ArgumentError if capture["input_sha256"] && capture["input_sha256"] != @input_digest
    @assembly = Provider::AccountData::OnchainWallet::Assembly.new(sources: sources, configuration: configuration,
      observed_at: observed_at, timezone: timezone, sync_start_date: sync_start_date, keyed_history: keyed_history, capture_reference: method(:capture_reference))
    @prefix = Archive.digest(reference)
    capture.fetch("fragments").each { |fragment| accept!(fragment) }
  end

  # nil means the durable response chain is ready for ordinary inventory pages.
  # Otherwise return an empty progress page containing exactly one new response.
  def advance(cursor:)
    validate_cursor!(cursor) if cursor
    operation = @assembly.next_operation
    return nil unless operation
    response = if operation["action"] == "fx_yahoo"
      auth = private_auth_for(operation)
      @client.read(operation, private_auth: auth, request_clock: -> { Time.current.getutc })
    else
      @client.read(operation)
    end
    fragment = { "index" => @assembly.operations.size, "previous_sha256" => @prefix, "operation" => operation,
      "response" => response, "fetched_at" => Time.current.getutc.iso8601(9) }
    accept!(fragment)
    continuation = self.cursor
    Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot", next_cursor: continuation,
      progress_cursor: continuation, evidence: { Archive::KEY => reference.merge("fragment" => fragment, "prefix_sha256" => @prefix) },
      coverage: { "scope" => "user_selected_assets", "absence_authoritative" => false },
      warnings: [ { "code" => "wallet_capture_in_progress" } ])
  rescue ArgumentError, KeyError, TypeError
    raise Provider::AccountData::InvalidResponse, "Wallet response chain does not match this request", cause: nil
  end

  def ready!
    raise Provider::AccountData::IncompletePage, "Wallet capture is not complete" if @assembly.next_operation
  end

  def snapshot(descriptor)
    ready!
    @assembly.snapshots.fetch(descriptor.values_at("chain", "wallet_address")).payload
  end

  def quotes(external_id)
    ready!
    @assembly.quotes.fetch(external_id)
  end

  def evidence
    ready!
    { Archive::KEY => reference.merge("prefix_sha256" => @prefix) }
  end

  def cursor(offset: nil)
    Base64.urlsafe_encode64(JSON.generate({ "version" => 1, "scope_sha256" => Archive.digest(@scope), "input_sha256" => @input_digest,
      "prefix_sha256" => @prefix, "index" => @assembly.operations.size, "offset" => offset }), padding: false)
  end

  def inventory_offset(cursor)
    return 0 unless cursor
    value = validate_cursor!(cursor)
    value["offset"] || 0
  end

  def inspect
    "#<#{self.class.name} captures=#{@assembly.operations.size}>"
  end

  private
    def reference
      { "version" => Archive::VERSION, "scope" => @scope, "input_sha256" => @input_digest }
    end

    def accept!(fragment)
      unless fragment.is_a?(Hash) && fragment.keys.sort == %w[fetched_at index operation previous_sha256 response] &&
          fragment["index"] == @assembly.operations.size && fragment["previous_sha256"] == @prefix
        raise ArgumentError
      end
      if fragment.dig("operation", "action") == "fx_yahoo"
        at = Provider::AccountData::OnchainWallet::YahooFxReader.exact_time(fragment.fetch("response").fetch("requested_at"))
        previous = @fragments.last&.fetch("fetched_at") || @scope.fetch("observed_at")
        raise ArgumentError unless at >= Time.iso8601(previous) && at <= Time.iso8601(fragment.fetch("fetched_at"))
      end
      @assembly.accept!(operation: fragment.fetch("operation"), response: fragment.fetch("response"), fetched_at: fragment.fetch("fetched_at"))
      @fragments << fragment
      @prefix = Archive.digest(fragment)
    end

    def capture_reference(action, **arguments)
      operation = { "action" => action, "chain" => nil, "address" => nil, "arguments" => arguments.deep_stringify_keys }
      fragment = @fragments.find { |value| value.fetch("operation") == operation } || raise(ArgumentError)
      { "index" => fragment.fetch("index"), "sha256" => Archive.digest(fragment) }
    end

    # A response accepted by this in-memory feeder is not yet a durable secret.
    # Re-read the exact admitted archive before lending any authentication. Its
    # grant/row lock scopes end inside build, before the following HTTP request.
    def private_auth_for(operation)
      arguments = operation.fetch("arguments")
      step = arguments.fetch("step")
      references = arguments.fetch("auth_refs")
      keys = { "cookie" => [], "crumb" => [ "cookie" ], "chart" => %w[cookie crumb] }.fetch(step)
      raise ArgumentError unless references.is_a?(Hash) && references.keys.sort == keys
      return {} if keys.empty?
      connection = ProviderConnection.find(@scope.fetch("connection_id"))
      sync = Sync.find(@scope.fetch("sync_id"))
      capture = Archive.build(connection: connection, sync: sync, observed_at: Time.iso8601(@scope.fetch("observed_at")))
      unless capture["scope"] == @scope && capture["input_sha256"] == @input_digest && capture["fragments"] == @fragments
        raise Provider::AccountData::StaleWriter, "Yahoo FX authentication requires the exact durable wallet prefix"
      end
      references.to_h do |name, value|
        raise ArgumentError unless value.is_a?(Hash) && value.keys.sort == %w[index sha256] && value["index"].is_a?(Integer) && value["index"] >= 0
        fragment = capture.fetch("fragments").fetch(value.fetch("index"))
        raise ArgumentError unless Archive.digest(fragment) == value["sha256"] && fragment.dig("operation", "action") == "fx_yahoo" &&
          fragment.dig("operation", "arguments", "step") == name
        [ name, fragment.fetch("response") ]
      end
    rescue ArgumentError, TypeError, KeyError, IndexError, ActiveRecord::RecordNotFound
      raise Provider::AccountData::StaleWriter, "Yahoo FX authentication does not belong to this durable capture prefix", cause: nil
    end

    def validate_cursor!(cursor)
      raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 4096
      value = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless value.is_a?(Hash) && value.keys.sort == %w[index input_sha256 offset prefix_sha256 scope_sha256 version] &&
          value.except("offset") == JSON.parse(Base64.urlsafe_decode64(self.cursor)).except("offset") &&
          (value["offset"].nil? || (value["offset"].is_a?(Integer) && value["offset"] >= 0))
        raise ArgumentError
      end
      value
    end
end
