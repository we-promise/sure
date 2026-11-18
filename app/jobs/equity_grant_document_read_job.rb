class EquityGrantDocumentReadJob < ApplicationJob
  queue_as :ai_low_priority

  # `user` is who uploaded the document; the AI route's consent check is theirs.
  def perform(statement, user = nil)
    AccountStatement::EquityGrantReader.new(statement, user: user).read!
  rescue AccountStatement::EquityGrantReader::Error => e
    DebugLogEntry.capture(
      category: "equity_grants", level: "warn", source: self.class.name, message: e.message,
      account: statement.account, user: user, metadata: { account_statement_id: statement.id }
    )
  end
end
