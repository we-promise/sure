class Provider::Myfund
  MyfundError = Class.new(StandardError)

  BASE_URL = "https://myfund.pl/API/v1/getPortfel.php"

  def initialize(api_key:, portfolio_name:)
    @api_key = api_key
    @portfolio_name = portfolio_name
  end

  def get_portfolio
    uri = URI(BASE_URL)
    uri.query = URI.encode_www_form(
      portfel: @portfolio_name,
      apiKey: @api_key,
      format: "json"
    )

    response = Net::HTTP.get_response(uri)

    unless response.is_a?(Net::HTTPSuccess)
      raise MyfundError, "myFund.pl API returned HTTP #{response.code}"
    end

    data = JSON.parse(response.body)

    if data.dig("status", "code") == 1
      error_text = data.dig("status", "text") || "Unknown error"
      raise MyfundError, "myFund.pl API error: #{error_text}"
    end

    data
  rescue JSON::ParserError => e
    raise MyfundError, "Invalid JSON response from myFund.pl: #{e.message}"
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout => e
    raise MyfundError, "Connection to myFund.pl failed: #{e.message}"
  end
end
