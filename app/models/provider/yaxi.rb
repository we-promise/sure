class Provider::Yaxi
  ENVIRONMENTS = %w[production integration].freeze
  Ticket = Data.define(:id, :token, :expires_at)

  Error = Class.new(Provider::Error)
  InvalidConfigurationError = Class.new(Error)
  InvalidResultError = Class.new(Error)

  SERVICES = %w[Accounts Balances Transactions].freeze
  TICKET_LIFETIME = 10.minutes

  attr_reader :key_id, :environment

  def initialize(key_id:, secret:, environment: "production")
    @key_id = key_id.to_s
    @secret = decode_secret(secret)
    @environment = environment.to_s

    raise InvalidConfigurationError, "YAXI key ID is missing" if @key_id.blank?
    raise InvalidConfigurationError, "YAXI secret must decode to at least 32 bytes" if @secret.bytesize < 32
    raise InvalidConfigurationError, "Unsupported YAXI environment: #{@environment}" unless @environment.in?(ENVIRONMENTS)
  end

  def issue_ticket(ticket_id:, service:, data: nil, expires_at: TICKET_LIFETIME.from_now)
    validate_service!(service)

    token = JWT.encode(
      {
        data: { service: service, id: ticket_id, data: data },
        exp: expires_at.to_i
      },
      @secret,
      "HS256",
      { kid: key_id }
    )

    Ticket.new(id: ticket_id, token: token, expires_at: expires_at)
  end

  def verify_result(token, expected_ticket_id:)
    payload, header = JWT.decode(
      token,
      @secret,
      true,
      algorithms: [ "HS256" ],
      verify_expiration: true
    )

    raise InvalidResultError, "YAXI result was signed by an unexpected key" unless ActiveSupport::SecurityUtils.secure_compare(header.fetch("kid", ""), key_id)

    result = payload.fetch("data")
    actual_ticket_id = result.fetch("ticketId")
    unless ActiveSupport::SecurityUtils.secure_compare(actual_ticket_id.to_s, expected_ticket_id.to_s)
      raise InvalidResultError, "YAXI result does not match the issued ticket"
    end

    result
  rescue JWT::DecodeError, KeyError => e
    raise InvalidResultError.new("Invalid YAXI result: #{e.message}")
  end

  def base_url
    environment == "integration" ? "https://integration.yaxi.tech/" : "https://api.yaxi.tech/"
  end

  private

    def decode_secret(secret)
      Base64.strict_decode64(secret.to_s)
    rescue ArgumentError
      raise InvalidConfigurationError, "YAXI secret is not valid Base64"
    end

    def validate_service!(service)
      return if service.to_s.in?(SERVICES)

      raise ArgumentError, "Unsupported YAXI service: #{service}"
    end
end
