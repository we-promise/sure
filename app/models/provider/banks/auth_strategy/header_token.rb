class Provider::Banks::AuthStrategy::HeaderToken
  def initialize(header_name:, token_prefix: nil, token:)
    @header_name = header_name
    @token_prefix = token_prefix
    @token = token
  end

  def apply!(request)
    value = @token_prefix.present? ? "#{@token_prefix} #{@token}" : @token
    request[@header_name] ||= value
  end
end

