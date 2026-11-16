class IbkrItem::Importer
  # A Flex request covers at most 365 days, so history older than the saved
  # query's period is fetched one window at a time, walking back up to the
  # four previous calendar years (IBKR doesn't document its reach). New windows are
  # only started this long into the import (IBKR's pacing makes each one take
  # a while), and the next sync resumes.
  HISTORY_TIME_BUDGET = 1.minute
  # Syncs a window is tried before it is given up (IBKR refuses it or has no
  # statements for it) or its failing rows are skipped. XML that does not
  # parse is more often a cut-off transfer, so it gets more tries before the
  # window is skipped.
  MAX_HISTORY_FAILURES = 3
  MAX_PARSE_FAILURES = MAX_HISTORY_FAILURES * 2

  attr_reader :ibkr_item, :ibkr_provider

  def initialize(ibkr_item, ibkr_provider:)
    @ibkr_item = ibkr_item
    @ibkr_provider = ibkr_provider
  end

  def import
    deadline = HISTORY_TIME_BUDGET.from_now
    xml_body = ibkr_provider.download_statement
    parsed_report = IbkrItem::ReportParser.new(xml_body).parse

    accounts_imported = 0
    ibkr_item.transaction do
      ibkr_item.upsert_ibkr_snapshot!(parsed_report[:metadata].merge("fetched_at" => Time.current.iso8601))

      parsed_report[:accounts].each do |account_data|
        next if account_data[:ibkr_account_id].blank?

        ibkr_account = ibkr_item.ibkr_accounts.find_or_initialize_by(ibkr_account_id: account_data[:ibkr_account_id])
        ibkr_account.upsert_from_ibkr_statement!(account_data)
        accounts_imported += 1
      end

      ibkr_item.update!(status: :good)
    end

    loop { break unless Time.current < deadline && import_history_window }

    {
      success: true,
      accounts_imported: accounts_imported
    }
  end

  private

    # Fetches the most recent missing window (so an account linked later
    # catches up without a hole) and imports it like the regular statement.
    # A window is recorded only once all its rows are imported, so one cut
    # short or with a row that failed is fetched again, up to
    # MAX_HISTORY_FAILURES syncs for the row. Returns whether the walk can go
    # on in this sync.
    def import_history_window
      pending = ibkr_item.linked_ibkr_accounts.includes(account_provider: :account).filter_map do |ibkr_account|
        state = history_state(ibkr_account)
        [ ibkr_account, state ] if state
      end
      return false if pending.empty?

      to_date = pending.map { |_, state| state["from"].to_date }.max - 1.day
      from_date = [ to_date - 364.days, oldest_available_date ].max
      pending.select! { |_, state| state["from"].to_date > to_date }
      statements = IbkrItem::ReportParser.new(ibkr_provider.download_statement(from_date: from_date, to_date: to_date)).parse[:accounts]

      complete = true
      until pending.empty?
        ibkr_account, state = pending.first
        data = statements.find { |row| row[:ibkr_account_id] == ibkr_account.ibkr_account_id }
        # Done once IBKR's reach is covered, the account did not exist yet, or
        # IBKR answered for another range than the one asked (it ignored fd/td).
        done = from_date == oldest_available_date || data.nil? || data[:statement]["from_date"].to_s.to_date != from_date
        failed_rows = data ? import_history_rows(ibkr_account, data) : []
        if failed_rows.empty? || rows_skipped?(ibkr_account, state, failed_rows)
          save_history_state(ibkr_account, state.merge("from" => from_date.iso8601, "done" => done, "failures" => 0, "row_failures" => 0, "parse_failures" => 0))
        else
          complete = false
        end
        pending.shift
      end
      complete
    rescue => e
      # Never fails the sync. A window IBKR keeps refusing (1003) or answering without
      # statements is given up after MAX_HISTORY_FAILURES syncs, and one whose XML does
      # not parse is skipped after MAX_PARSE_FAILURES; any other error (busy, "try
      # again shortly", network) only stops this one.
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "warn", message: "IBKR history import stopped: #{e.class}: #{e.message}",
        source: self.class.name, provider_key: "ibkr", family: ibkr_item.family, metadata: { error_code: e.try(:error_code) }.compact
      )
      return skip_unparseable_window(pending, from_date, to_date) if e.is_a?(IbkrItem::ReportParser::ParseError) && e.cause.is_a?(Nokogiri::XML::SyntaxError)
      return false unless no_statements_error?(e)

      pending&.each do |ibkr_account, state|
        failures = state["failures"].to_i + 1
        save_history_state(ibkr_account, state.merge("failures" => failures, "done" => failures >= MAX_HISTORY_FAILURES))
      end
      false
    end

    # IBKR refused the window (1003), or answered it with well-formed XML that
    # holds no statements.
    def no_statements_error?(error)
      return error.error_code.to_s == "1003" if error.respond_to?(:error_code)

      error.is_a?(IbkrItem::ReportParser::ParseError)
    end

    # Rows that keep failing are given up after MAX_HISTORY_FAILURES syncs, so
    # they don't hold back the rest of the window or the older ones. Until
    # then the account keeps the window, and the next sync fetches it again.
    def rows_skipped?(ibkr_account, state, failed_rows)
      row_failures = state["row_failures"].to_i + 1
      skipped = row_failures >= MAX_HISTORY_FAILURES
      save_history_state(ibkr_account, state.merge("row_failures" => row_failures)) unless skipped

      DebugLogEntry.capture(
        category: "provider_sync_error", level: skipped ? "error" : "warn",
        message: "IBKR history rows #{skipped ? "skipped" : "to retry"} after #{row_failures} failed imports: #{failed_rows.join(", ")}",
        source: self.class.name, provider_key: "ibkr", account_provider: ibkr_account.account_provider, family: ibkr_item.family,
        metadata: { ibkr_account_id: ibkr_account.ibkr_account_id, failed_rows: failed_rows }
      )
      skipped
    end

    # A window whose XML still does not parse after MAX_PARSE_FAILURES syncs
    # is skipped, and the walk goes on with the older ones.
    def skip_unparseable_window(pending, from_date, to_date)
      pending.each do |ibkr_account, state|
        parse_failures = state["parse_failures"].to_i + 1
        if parse_failures < MAX_PARSE_FAILURES
          save_history_state(ibkr_account, state.merge("parse_failures" => parse_failures))
          next
        end

        DebugLogEntry.capture(
          category: "provider_sync_error", level: "error",
          message: "IBKR history window #{from_date}..#{to_date} skipped: its XML did not parse in #{parse_failures} syncs",
          source: self.class.name, provider_key: "ibkr", account_provider: ibkr_account.account_provider, family: ibkr_item.family,
          metadata: { ibkr_account_id: ibkr_account.ibkr_account_id }
        )
        save_history_state(ibkr_account, state.merge("from" => from_date.iso8601, "done" => from_date == oldest_available_date,
                                                     "failures" => 0, "row_failures" => 0, "parse_failures" => 0))
      end
      false
    end

    # Kept per linked Sure account, so linking another one walks back again.
    # nil when there is nothing left to fetch or the account is not synced.
    def history_state(ibkr_account)
      account = ibkr_account.current_account
      return if account.nil? || account.pending_deletion? || account.disabled?

      metadata = ibkr_account.institution_metadata.to_h
      state = metadata["history"].to_h
      state = { "account_id" => account.id, "from" => metadata["statement_from_date"] } unless state["account_id"] == account.id
      state if state["from"].present? && !state["done"] && state["from"].to_date > oldest_available_date
    end

    def oldest_available_date
      Date.current.beginning_of_year - 4.years
    end

    # The window's trades and cash, through the same processor as the
    # regular statement; the stored payload stays the current statement's.
    def import_history_rows(ibkr_account, data)
      ibkr_account.raw_activities_payload = data.slice(:trades, :cash_transactions)
      IbkrAccount::ActivitiesProcessor.new(ibkr_account).process[:failed_rows]
    ensure
      ibkr_account.restore_attributes([ :raw_activities_payload ])
    end

    def save_history_state(ibkr_account, state)
      ibkr_account.update!(institution_metadata: ibkr_account.institution_metadata.to_h.merge("history" => state))
    end
end
