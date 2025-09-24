class Provider::Banks::AuthStrategy::BearerToken
  def initialize(token)
    @token = token
  end

  def apply!(request)
    request['Authorization'] ||= "Bearer #{@token}"
  end
end

