class YahooFinanceHealthCheckJob < ApplicationJob
  def perform
    Provider::YahooFinance.new.refresh_health_status
  end
end
