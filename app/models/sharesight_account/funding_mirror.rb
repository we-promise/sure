# Top-ups to the broker from a bank account that's already in Sure. Sharesight
# never sees them, so Sure would only show the bank side, as spending. While
# the broker holds the cash, any bank transaction with one of the funding terms
# in its name or notes gets mirrored into the investment account and linked as
# a transfer.
class SharesightAccount::FundingMirror
  include SharesightAccount::TransferLinking

  PREFIX = "sharesight_funding_".freeze

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def mirror
    return unless account

    mirrored = funding_entries.filter_map do |bank_entry|
      leg = book_mirror(bank_entry)
      link_transfer!(leg, bank_entry)
      leg.external_id
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "SharesightAccount::FundingMirror - Failed to mirror #{bank_entry.id}: #{e.message}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight"
      )
      nil
    end

    remove_stale_mirrors(mirrored)
  end

  private

    def account
      @account ||= @sharesight_account.current_account
    end

    def funding_account
      @sharesight_account.funding_account
    end

    def funding_entries
      terms = @sharesight_account.funding_terms
      return [] unless funding_account && terms.any?

      patterns = terms.map { |term| "%#{Entry.sanitize_sql_like(term)}%" }
      funding_account.entries
        .where(entryable_type: "Transaction", excluded: false)
        .where(date: ..Date.current)
        .where("entries.name ILIKE ANY (ARRAY[?]) OR entries.notes ILIKE ANY (ARRAY[?])", patterns, patterns)
        .includes(:entryable)
        .select { |entry| @sharesight_account.holds_cash_at_broker_on?(entry.date) && !@sharesight_account.before_sync_start?(entry.date) }
        .reject { |entry| entry.amount.zero? || transferred_elsewhere?(entry, account) }
    end

    # Money out of the bank lands at the broker, and the other way round.
    def book_mirror(bank_entry)
      Account::ProviderImportAdapter.new(account).import_transaction(
        external_id: "#{PREFIX}#{bank_entry.id}",
        amount: -bank_entry.amount,
        currency: bank_entry.currency,
        date: bank_entry.date,
        name: bank_entry.amount.positive? ? "Transfer from #{funding_account.name}" : "Transfer to #{funding_account.name}",
        source: "sharesight",
        investment_activity_label: "Transfer",
        allow_heuristic_matching: false,
        extra: { sharesight: { funding_entry_id: bank_entry.id } }
      )
    end

    def remove_stale_mirrors(current)
      account.entries
        .where(source: "sharesight")
        .where("entries.external_id LIKE ?", "#{Entry.sanitize_sql_like(PREFIX)}%")
        .where.not(external_id: current)
        .destroy_all
    end
end
