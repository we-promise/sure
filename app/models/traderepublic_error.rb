# Custom error class for Trade Republic
class TraderepublicError < StandardError
  attr_reader :error_code

  def initialize(message, error_code = :unknown_error)
    super(message)
    @error_code = error_code
  end
end
