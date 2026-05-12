class ExchangeRatesController < ApplicationController
  def show
    # Pure currency-to-currency exchange rate lookup
    unless params[:from].present? && params[:to].present?
      return render json: { error: "from and to currencies are required" }, status: :bad_request
    end

    from_currency = params[:from].upcase
    to_currency = params[:to].upcase

    # Same currency returns 1.0
    if from_currency == to_currency
      return render json: { rate: 1.0, same_currency: true }
    end

    # Parse date
    begin
      date = params[:date].present? ? Date.parse(params[:date]) : Date.current
    rescue ArgumentError, TypeError
      return render json: { error: "Invalid date format" }, status: :bad_request
    end

    begin
      rate_obj = ExchangeRate.find_or_fetch_rate(from: from_currency, to: to_currency, date: date)
    rescue StandardError
      return render json: { error: "Failed to fetch exchange rate" }, status: :bad_request
    end

    if rate_obj.nil?
      return render json: { error: "Exchange rate not found" }, status: :not_found
    end

    rate_value = rate_obj.is_a?(Numeric) ? rate_obj : rate_obj.rate
    render json: { rate: rate_value.to_f }
  end
end
