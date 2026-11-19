class InvestmentDocumentReadJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(statement, kind)
    AccountStatement::InvestmentDataReader.new(statement, kind: kind).read!
  rescue AccountStatement::InvestmentDataReader::Error => e
    Rails.logger.warn("[InvestmentDocumentReadJob] #{statement.id}: #{e.message}")
  end
end
