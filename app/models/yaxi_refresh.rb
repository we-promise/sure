class YaxiRefresh
  TRANSACTION_LOOKBACK = 3.days

  attr_reader :item, :user, :provider

  def initialize(item:, user:, provider: Provider::YaxiAdapter.build_provider)
    @item = item
    @user = user
    @provider = provider
  end

  def preparation
    ActiveRecord::Base.transaction do
      accounts = refreshable_accounts.includes(:account).to_a
      last_entry_dates = Entry.where(
        account_id: accounts.filter_map { |account| account.account&.id },
        source: "yaxi",
        date: ..Date.current
      )
        .group(:account_id)
        .maximum(:date)
      oldest_pending_dates = Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(
          account_id: accounts.filter_map { |account| account.account&.id },
          source: "yaxi",
          date: ..Date.current
        )
        .where("(transactions.extra -> 'yaxi' ->> 'pending')::boolean = true")
        .group(:account_id)
        .minimum(:date)

      tickets = accounts.map do |account|
        earliest_date = 90.days.ago.to_date
        last_entry_date = last_entry_dates[account.account&.id]
        overlap_start = last_entry_date ? last_entry_date - TRANSACTION_LOOKBACK : earliest_date
        oldest_pending_date = oldest_pending_dates[account.account&.id]
        from = [ [ overlap_start, oldest_pending_date ].compact.min, earliest_date ].max
        ticket = issue_ticket("Transactions", account: account.reference, range: { from: from.iso8601 })
        { account_id: account.id, ticket_id: ticket.id, token: ticket.token }
      end

      {
        balances_ticket: issue_ticket("Balances"),
        transaction_tickets: tickets,
        account_references: accounts.map(&:reference)
      }
    end
  end

  def apply!(balances_ticket_id:, balances_result_jwt:, transaction_results:)
    ActiveRecord::Base.transaction do
      balances_ticket, balances_result = verify_result!(
        service: "Balances",
        ticket_id: balances_ticket_id,
        token: balances_result_jwt
      )
      verified_transactions = transaction_results.map { |result| verify_transaction!(result) }

      apply_balances!(balances_result.fetch("data"))
      verified_transactions.each do |account, ticket, transactions|
        range_from = Date.iso8601(ticket.service_data.fetch("range").fetch("from"))
        account.import_transactions!(transactions, from: range_from)
        ticket.consume!
      end
      balances_ticket.consume!
      item.update!(last_refreshed_at: Time.current, status: :good)
    end
  end

  private

    def refreshable_accounts
      accounts = item.yaxi_accounts
      accounts.where.not(iban: [ nil, "" ]).or(accounts.where.not(number: [ nil, "" ]))
    end

    def issue_ticket(service, service_data = nil)
      YaxiTicket.issue!(family: item.family, user: user, service: service, service_data: service_data)
    end

    def verify_result!(service:, ticket_id:, token:)
      YaxiTicket.verify!(
        family: item.family,
        user: user,
        service: service,
        ticket_id: ticket_id,
        token: token,
        provider: provider
      )
    end

    def verify_transaction!(result)
      ticket, verified_result = verify_result!(
        service: "Transactions",
        ticket_id: result.fetch(:ticket_id),
        token: result.fetch(:result_jwt)
      )
      account = item.yaxi_accounts.find(result.fetch(:account_id))
      expected_reference = ticket.service_data.fetch("account").with_indifferent_access
      unless account.reference.with_indifferent_access == expected_reference
        raise Provider::Yaxi::InvalidResultError, "YAXI transaction ticket does not match the selected account"
      end

      [ account, ticket, verified_result.fetch("data") ]
    end

    def apply_balances!(payload)
      balance_entries(payload).each do |entry|
        entry = entry.with_indifferent_access
        account = find_account(entry.fetch("account"))
        raise Provider::Yaxi::InvalidResultError, "YAXI balance does not match a connected account" unless account

        account.apply_balance_result!(entry.fetch("balances"))
      end
    end

    def balance_entries(payload)
      Array.wrap(payload).flat_map do |group|
        group = group.with_indifferent_access
        group[:balances].present? ? Array(group[:balances]) : [ group ]
      end
    end

    def find_account(reference)
      reference = reference.with_indifferent_access
      candidates = if reference[:iban].present?
        item.yaxi_accounts.where(iban: reference[:iban])
      elsif reference[:number].present?
        item.yaxi_accounts.where(number: reference[:number])
      else
        item.yaxi_accounts.none
      end
      return candidates.find_by(currency: reference[:currency]) if reference[:currency].present?

      candidates.one? ? candidates.first : nil
    end
end
