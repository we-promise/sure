class Family::SyncCompleteEvent
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def broadcast
    # Dashboard partials can occasionally raise when rendered from background jobs
    # (e.g., if intermediate series values are nil during a sync). Make broadcasts
    # resilient so a post-sync UI refresh never causes the overall sync to report an error.
    begin
      family.broadcast_replace(
        target: "balance-sheet",
        partial: "pages/dashboard/balance_sheet",
        locals: { balance_sheet: family.balance_sheet }
      )
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent balance_sheet broadcast failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end

    begin
      family.broadcast_replace(
        target: "net-worth-chart",
        partial: "pages/dashboard/net_worth_chart",
        locals: { balance_sheet: family.balance_sheet, period: Period.last_30_days }
      )
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent net_worth_chart broadcast failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end
end
