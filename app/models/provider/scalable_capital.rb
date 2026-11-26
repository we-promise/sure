require "open3"
require "timeout"

class Provider::ScalableCapital
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class InvalidResponse < Error; end
  class NoOvernightAccount < Error; end
  class OvernightDiscoveryUnavailable < Error
    attr_reader :ids

    def initialize(ids = [])
      @ids = ids
      super("Scalable could not list available Overnight Savings accounts")
    end
  end

  COMMAND_TIMEOUT = 45
  OUTPUT_LIMIT = 8.megabytes
  CLI_ENV = %w[HOME PATH XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS HTTPS_PROXY HTTP_PROXY NO_PROXY SSL_CERT_FILE SSL_CERT_DIR].freeze
  MAX_PAGES = 100
  READ_INTERVAL = 1
  AUTH_ERRORS = %w[no_session refresh_relogin_required auth_grant_not_enabled].freeze
  OVERNIGHT_CHOICES = /\AUnable to resolve overnight savings account id: multiple active overnight accounts found \[(.+)\]\. Provide --savings-account-id <ID>\.\z/

  def self.executable
    ENV["SCALABLE_CAPITAL_CLI_PATH"].presence
  end

  def initialize(executable: self.class.executable)
    @executable = executable
  end

  def identity
    data = read("whoami")
    raise AuthenticationError, "Sign in with Scalable CLI 1.3 or later in local read-only mode" unless data.dig("session", "local_read_only") == true

    id = data.dig("result", "personOverview", "id")
    raise InvalidResponse, "Scalable did not return an account identity" unless ScalableCapitalItem.valid_source_id?(id)

    id
  end

  def portfolios
    values = read("broker", "portfolios")["portfolios"]
    unless values.is_a?(Array) && values.all? { |row| row.is_a?(Hash) && ScalableCapitalItem.valid_source_id?(row["portfolio_id"]) }
      raise InvalidResponse, "Scalable returned an invalid portfolio list"
    end

    values.pluck("portfolio_id").uniq
  end

  def overnight_accounts
    [ overnight(nil) ]
  rescue NoOvernightAccount
    []
  rescue OvernightDiscoveryUnavailable => error
    raise if error.ids.empty?

    error.ids.map do |id|
      data = overnight(id)
      raise InvalidResponse, "Scalable returned a different Overnight Savings account" unless data["savings_account_id"] == id

      data
    end
  end

  def overview(portfolio_id)
    read("broker", "overview", "--portfolio-id", portfolio_id)
  end

  def holdings(portfolio_id)
    read("broker", "holdings", "--portfolio-id", portfolio_id)
  end

  def cash(portfolio_id)
    read("broker", "cash-breakdown", "--portfolio-id", portfolio_id)
  end

  def trade(portfolio_id, id)
    read("broker", "transaction", "details", "--portfolio-id", portfolio_id, "--transaction-id=#{id}")
  end

  def overnight(savings_id)
    if savings_id
      read("overnight", "--savings-account-id", savings_id)
    else
      read("overnight")
    end
  end

  def broker_transactions(portfolio_id, since:, before:, &block)
    each_page([ "broker", "transactions", "--portfolio-id", portfolio_id ], since: since, before: before, &block)
  end

  def overnight_transactions(savings_id, since:, before:, &block)
    each_page([ "overnight", "transactions", "--savings-account-id", savings_id ], since: since, before: before, &block)
  end

  private

    def each_page(args, since:, before:)
      args += [ "--from-time", since.iso8601, "--to-time", before.iso8601, "--page-size", "100" ]
      seen = Set.new
      cursor = nil
      MAX_PAGES.times do
        data = read(*args, *(cursor ? [ "--cursor=#{cursor}" ] : []))
        page = data.fetch("result", data)
        raise InvalidResponse, "Scalable returned an invalid history page" unless page.is_a?(Hash) && page["items"].is_a?(Array)

        yield data, page["items"]
        cursor = page.fetch("cursor") { raise InvalidResponse, "Scalable history cursor is missing" }
        return if cursor.nil?
        unless cursor.is_a?(String) && cursor.present? && seen.add?(cursor)
          raise InvalidResponse, "Scalable returned a repeated or invalid history cursor"
        end
      end
      raise InvalidResponse, "Scalable history exceeded the page limit"
    end

    def read(*args)
      raise Error, "Scalable CLI is not configured" unless @executable&.start_with?("/")

      # A single command sequence per connection is paced, including trade details.
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep(@next_read_at - now) if @next_read_at && @next_read_at > now
      @next_read_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READ_INTERVAL

      output, status = capture(args)
      envelope = JSON.parse(output, decimal_class: BigDecimal)
      raise InvalidResponse, "Scalable CLI returned an invalid response" unless envelope.is_a?(Hash)

      if status.success? && envelope["ok"] == true && envelope["data"].is_a?(Hash)
        return envelope["data"]
      end

      code = envelope["error"].is_a?(Hash) ? envelope["error"]["code"] : nil
      if AUTH_ERRORS.include?(code)
        raise AuthenticationError, "Sign in again with the Scalable CLI, then retry"
      elsif code == "overnight_selection_required"
        message = envelope.dig("error", "message")
        if message == "Unable to resolve overnight savings account id: no accessible overnight accounts found."
          raise NoOvernightAccount, "No active Overnight Savings account was found"
        end
        raise OvernightDiscoveryUnavailable.new(overnight_candidates(message))
      elsif code == "rate_limited"
        raise Error, "Scalable is rate limiting requests. Wait before syncing again"
      end

      # Avoid surfacing command output or CLI error bodies in sync history or logs.
      raise Error, "Scalable CLI read failed"
    rescue JSON::ParserError
      raise InvalidResponse, "Scalable CLI returned invalid JSON"
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "Scalable CLI is unavailable to the worker"
    end

    def overnight_candidates(message)
      # CLI 1.3 only provides this list in its bounded error text. An incomplete
      # response must not look like there are no other accounts to select.
      choices = OVERNIGHT_CHOICES.match(message.to_s)&.[](1)
      return [] unless choices

      ids = choices.split(/(?<=, personal\)|, junior\)), /).map do |choice|
        /\A([A-Za-z0-9][A-Za-z0-9_-]{0,127}) \([^\r\n]*, (?:personal|junior)\)\z/.match(choice)&.[](1)
      end
      ids.size > 1 && ids.none?(&:nil?) && ids.uniq == ids ? ids : []
    end

    def capture(args)
      Open3.popen2(ENV.slice(*CLI_ENV), [ @executable, @executable ], *args, "--json", err: File::NULL, unsetenv_others: true) do |stdin, stdout, child|
        stdin.close
        begin
          Timeout.timeout(COMMAND_TIMEOUT) do
            output = stdout.read(OUTPUT_LIMIT + 1)
            raise InvalidResponse, "Scalable CLI response exceeded the size limit" if output.to_s.bytesize > OUTPUT_LIMIT

            [ output.to_s, child.value ]
          end
        rescue Timeout::Error
          raise Error, "Scalable CLI read timed out"
        ensure
          if child.alive?
            begin
              Process.kill("KILL", child.pid)
            rescue Errno::ESRCH
              # The process exited as the timeout was handled.
            end
          end
        end
      end
    end
end
