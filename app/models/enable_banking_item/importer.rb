class EnableBankingItem::Importer
  include CurrencyNormalizable

  # Maximum number of pagination requests to prevent infinite loops
  # Enable Banking typically returns ~100 transactions per page, so 100 pages = ~10,000 transactions
  MAX_PAGINATION_PAGES = 100

  # A first fetch with strategy=longest can span many years, and Enable Banking
  # says it may return empty pages with a continuation key, so it gets a larger
  # budget. Hitting the cap keeps the partial result and reports the fetch as
  # truncated (see fetch_and_store_transactions).
  MAX_LONGEST_PAGINATION_PAGES = 1000

  # Under PSD2, access without a fresh SCA covers the last 90 days, and some
  # ASPSPs reject a date_from at exactly 90 days. The newest stored row only
  # pulls an incremental fetch back this far, the same 89 days the provider's
  # WRONG_TRANSACTIONS_PERIOD fallback starts with (see
  # incremental_sync_start_date).
  STORED_ROW_LOOKBACK_LIMIT = Provider::EnableBanking::FALLBACK_TRANSACTIONS_DATE_FROM_DAYS.first.days

  # Prefer booked ledger balances for net worth/current_balance. Available balances
  # can include an arranged overdraft facility for some ASPSPs (for example CGD PT),
  # so they are only a last-resort fallback.
  #
  # OPBD/PRCD rank above XPCD despite being period-boundary snapshots (opening of
  # the current period / closing of the previous one) rather than "instant" values:
  # this mirrors CLBD outranking ITBD above, a reconciled booked figure is trusted
  # over one that includes unconfirmed pending activity, even if it's up to a day
  # older. That trade-off assumes the staleness is bounded to about a day, so
  # select_current_balance below guards it with the optional `reference_date` field
  # (see PERIOD_BOUNDARY_TYPES): if the same response also carries a materially
  # newer XPCD/CLAV/ITAV, the fresher one wins instead.
  BALANCE_TYPE_PRIORITY = %w[
    CLBD closingBooked
    ITBD interimBooked
    OPBD openingBooked
    PRCD previouslyClosedBooked
    XPCD expected
    CLAV closingAvailable
    ITAV interimAvailable
  ].freeze

  # With "Balance is available credit" on for a credit card, the bank's figure
  # is the available credit, so available types come first. Some cards report
  # the credit limit as the booked balance (mBank PL: ITBD = limit, ITAV =
  # available credit). XPCD (expected) keeps its place after the booked types:
  # it is a projected booked balance, not an available-credit figure.
  AVAILABLE_CREDIT_BALANCE_TYPE_PRIORITY = (%w[
    CLAV closingAvailable
    ITAV interimAvailable
  ] + BALANCE_TYPE_PRIORITY).uniq.freeze

  PERIOD_BOUNDARY_TYPES = %w[opbd openingbooked prcd previouslyclosedbooked].freeze

  # Only these types may outrank OPBD/PRCD on freshness (see fresher_balance) —
  # the same accounting-semantics exclusion as BALANCE_TYPE_PRIORITY itself, so a
  # forward-looking FWAV or an informational INFO/OTHR can't override a legitimate
  # booked figure just by carrying a later reference_date. Compared against an
  # already-normalized balance_type (see normalize_balance_type), so both ISO
  # codes and Enable Banking's descriptive spellings are listed here pre-normalized,
  # mirroring BALANCE_TYPE_PRIORITY's own XPCD/CLAV/ITAV entries above.
  FRESHNESS_BALANCE_TYPES = %w[xpcd expected clav closingavailable itav interimavailable].freeze

  # Two same-type balances within this distance of each other (or of an expected
  # value) are treated as equal when breaking a tie (see resolve_same_type_balances).
  BALANCE_TIEBREAK_TOLERANCE = BigDecimal("0.01")

  # Tiebreak stages backed by evidence rather than a heuristic. A balance chosen
  # this way (or without any tiebreak) is stored as balance_evidence_verified;
  # the processor promotes that to balance_verified only once the balance has
  # been written as the anchor, which lets the next sync trust that anchor.
  VERIFIED_TIEBREAK_STAGES = %i[last_committed_transaction credit_limit anchor].freeze

  NETWORK_ERRORS = [
    ::SocketError,
    ::Errno::ECONNREFUSED,
    ::Timeout::Error,
    ::Net::ReadTimeout,
    ::Net::OpenTimeout
  ].freeze

  attr_reader :enable_banking_item, :enable_banking_provider

  def initialize(enable_banking_item, enable_banking_provider:)
    @enable_banking_item = enable_banking_item
    @enable_banking_provider = enable_banking_provider
  end

  def import
    unless enable_banking_item.session_valid?
      enable_banking_item.update!(status: :requires_update)
      return { success: false, error: I18n.t("enable_banking_items.errors.session_invalid"), accounts_updated: 0, transactions_imported: 0 }
    end

    session_data = fetch_session_data
    unless session_data
      error_msg = @session_error || I18n.t("enable_banking_items.errors.unexpected")
      return { success: false, error: error_msg, accounts_updated: 0, transactions_imported: 0 }
    end

    # Store raw payload
    begin
      enable_banking_item.upsert_enable_banking_snapshot!(session_data)
    rescue => e
      Rails.logger.error "EnableBankingItem::Importer - Failed to store session snapshot: #{e.message}"
    end

    sync_uids_from_accounts_data(session_data[:accounts])

    # Update accounts from session
    accounts_updated = 0
    accounts_failed = 0

    if session_data[:accounts].present?
      existing_uids = enable_banking_item.enable_banking_accounts
                                         .joins(:account_provider)
                                         .pluck(:uid)
                                         .map(&:to_s)

      # Enable Banking API returns accounts as an array of UIDs (strings) in the session response
      # We need to handle both array of strings and array of hashes
      session_data[:accounts].each do |account_data|
        # Handle both string UIDs and hash objects
        # Use identification_hash as the stable identifier across sessions
        uid = if account_data.is_a?(String)
          account_data
        elsif account_data.is_a?(Hash)
          (account_data[:identification_hash] || account_data[:uid] || account_data["identification_hash"] || account_data["uid"])&.to_s
        else
          nil
        end

        next unless uid.present?

        # Only update if this account was previously linked
        next unless existing_uids.include?(uid)

        begin
          # For string UIDs, we don't have account data to update - skip the import_account call
          # The account data will be fetched via balances/transactions endpoints
          if account_data.is_a?(Hash)
            import_account(account_data)
            accounts_updated += 1
          end
        rescue => e
          accounts_failed += 1
          @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
          Rails.logger.error "EnableBankingItem::Importer - Failed to update account #{uid}: #{e.message}"
        end
      end
    end

    # Fetch balances and transactions for linked accounts. Balance refreshes are
    # best-effort: a balance endpoint failure should keep the previous balance and
    # must not prevent transaction sync for the same account.
    transactions_imported = 0
    transactions_failed = 0
    transactions_truncated = 0
    balances_failed = 0

    linked_accounts_query = enable_banking_item.enable_banking_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    linked_accounts_query.each do |enable_banking_account|
      begin
        result = fetch_and_store_transactions(enable_banking_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
          transactions_truncated += 1 if result[:truncated]
        else
          transactions_failed += 1
          @sync_error = promote_session_invalid(@sync_error, result[:error])
        end
      rescue => e
        transactions_failed += 1
        @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
        Rails.logger.error "EnableBankingItem::Importer - Failed to process account #{enable_banking_account.uid}: #{e.message}"
      end

      # Runs after the transaction fetch so a same-type balance tie can be checked
      # against this sync's booked transactions (see resolve_same_type_balances),
      # and in its own rescue so a failed transaction fetch never skips it.
      begin
        balances_failed += 1 unless fetch_and_update_balance(enable_banking_account)
      rescue => e
        balances_failed += 1
        @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
        Rails.logger.error "EnableBankingItem::Importer - Failed to update balance for account #{enable_banking_account.uid}: #{e.message}"
      end
    end

    result = {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_updated: accounts_updated,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed,
      balances_failed: balances_failed,
      transactions_truncated: transactions_truncated
    }

    result[:error] = @sync_error || I18n.t("enable_banking_items.errors.unexpected") if !result[:success]
    result
  end

  private

    # @param session_level [Boolean] true only for the top-level GET /sessions call.
    #   A session-level 401/404 means the consent is genuinely dead and the user
    #   must re-authorize. Per-account 401/404 (a stale account UID, a transient
    #   hiccup on one account) must NOT mark the whole connection requires_update —
    #   doing so is what made every sync report "session expired". Those are recorded
    #   as ordinary sync errors and retried on the next sync.
    def handle_sync_error(exception, session_level: false)
      # Check the underlying cause first, then the exception itself
      exceptions = [ exception.cause, exception ].compact

      provider_error = exceptions.find { |ex| ex.is_a?(Provider::EnableBanking::EnableBankingError) }

      # Handle session expiration status update (session-level failures only)
      if session_level && provider_error && [ :unauthorized, :not_found ].include?(provider_error.error_type)
        enable_banking_item.update!(status: :requires_update)
        return I18n.t("enable_banking_items.errors.session_invalid")
      end

      is_network_error = exceptions.any? do |ex|
        NETWORK_ERRORS.any? { |err| ex.is_a?(err) } ||
          (ex.is_a?(Provider::EnableBanking::EnableBankingError) && [ :request_failed, :timeout ].include?(ex.error_type))
      end

      if is_network_error
        I18n.t("enable_banking_items.errors.network_unreachable")
      elsif provider_error
        I18n.t("enable_banking_items.errors.api_error")
      else
        I18n.t("enable_banking_items.errors.unexpected")
      end
    end

    def fetch_session_data
      session_data = enable_banking_provider.get_session(session_id: enable_banking_item.session_id)
      # Keep the local expiry in sync with the authoritative value from the API so
      # session_valid? doesn't drift (premature "expired" or stale "still valid").
      enable_banking_item.reconcile_session_expiry!(session_data)
      session_data
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "EnableBankingItem::Importer - Enable Banking API error: #{e.message}"
      @session_error = handle_sync_error(e, session_level: true)
      nil
    rescue => e
      Rails.logger.error "EnableBankingItem::Importer - Unexpected error fetching session: #{e.class} - #{e.message}"
      @session_error = handle_sync_error(e, session_level: true)
      nil
    end

    def import_account(account_data)
      # Use identification_hash as the stable identifier across sessions
      uid = account_data[:identification_hash] || account_data[:uid]

      enable_banking_account = find_enable_banking_account_by_hash(uid)
      return unless enable_banking_account

      enable_banking_account.upsert_enable_banking_snapshot!(account_data)
      enable_banking_account.save!
    end

    def fetch_and_update_balance(enable_banking_account)
      balance_data = enable_banking_provider.get_account_balances(
        account_id: enable_banking_account.api_account_id,
        psu_headers: enable_banking_item.build_psu_headers
      ).with_indifferent_access

      # Enable Banking returns an array of balances. Use booked ledger balances for
      # current_balance/net worth before considering available balances. Available
      # balances can include arranged overdraft facilities and overstate cash.
      balances = Array(balance_data[:balances]).map { |balance| balance.with_indifferent_access }

      if balances.empty?
        mark_balance_unavailable(enable_banking_account)
        return false
      end

      currency, kept, skipped = split_balances_by_currency(balances, enable_banking_account)
      balance, tiebreak_stage = select_current_balance(
        kept, enable_banking_account, prefer_available: prefer_available_balance?(enable_banking_account)
      )

      unless balance.present?
        mark_balance_unavailable(enable_banking_account)
        return false
      end

      amount = balance.dig(:balance_amount, :amount) || balance[:amount]

      unless amount.present?
        mark_balance_unavailable(enable_banking_account)
        return false
      end

      indicator = balance[:credit_debit_indicator].to_s.upcase
      parsed_amount = amount.to_d

      # Enable Banking uses positive amounts for both credit and debit.
      # DBIT indicates a negative balance (money owed/withdrawn).
      parsed_amount = -parsed_amount if indicator == "DBIT"

      enable_banking_account.update!(
        current_balance: parsed_amount,
        currency: balance_currency(balance) || enable_banking_account.currency,
        balance_evidence_verified: tiebreak_stage.nil? || VERIFIED_TIEBREAK_STAGES.include?(tiebreak_stage)
      )
      # Only now is the chosen-currency balance known to be the one in use.
      capture_skipped_currency_balances(enable_banking_account, currency, skipped)

      true
    rescue Provider::EnableBanking::EnableBankingError => e
      @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
      Rails.logger.error "EnableBankingItem::Importer - Error fetching balance for account #{enable_banking_account.uid}: #{e.message}"
      capture_balance_sync_error(enable_banking_account, e)
      mark_balance_unavailable(enable_banking_account)
      false
    rescue => e
      @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
      Rails.logger.error "EnableBankingItem::Importer - Unexpected error fetching balance for account #{enable_banking_account.uid}: #{e.class} - #{e.message}"
      capture_balance_sync_error(enable_banking_account, e)
      mark_balance_unavailable(enable_banking_account)
      false
    end

    # Multi-currency wallets such as PayPal report one balance per currency
    # under the same balance type (EUR, CAD, USD, ...). Keep the balances in
    # the currency the accounts endpoint reports for the account, else in the
    # first currency listed, which is the wallet's primary one. Otherwise
    # the same-type tiebreak would choose between currencies, so an empty
    # USD balance replaced the EUR one and switched the account to USD.
    # Returns the chosen currency, the balances in it and the ones left out.
    def split_balances_by_currency(balances, enable_banking_account)
      currencies = balances.filter_map { |balance| balance_currency(balance) }.uniq
      return [ currencies.first, balances, [] ] if currencies.size <= 1

      account_currency = snapshot_currency(enable_banking_account)
      currency = currencies.include?(account_currency) ? account_currency : currencies.first
      kept, skipped = balances.partition { |balance| balance_currency(balance) == currency }
      [ currency, kept, skipped ]
    end

    def balance_currency(balance)
      parse_currency(balance.dig(:balance_amount, :currency) || balance[:currency])
    end

    # Read from the raw snapshot, not the stored column: the stored currency
    # may already be the wrong one picked from a multi-currency response.
    # PayPal reports XXX (no currency) for the wallet; parse_currency turns
    # that into nil, so the first listed currency is used.
    def snapshot_currency(enable_banking_account)
      payload = enable_banking_account.raw_payload
      parse_currency(payload.with_indifferent_access[:currency]) if payload.is_a?(Hash)
    end

    # A non-zero balance in another currency is money the account leaves out;
    # make that visible to support instead of dropping it silently.
    def capture_skipped_currency_balances(enable_banking_account, currency, skipped)
      funded = skipped.filter_map do |balance|
        amount = balance.dig(:balance_amount, :amount) || balance[:amount]
        next if amount.blank? || amount.to_d.zero?

        { currency: balance_currency(balance), balance_type: balance[:balance_type], amount: amount.to_s }
      end
      return if funded.empty?

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "info",
        message: "Enable Banking account holds balances in other currencies; only the #{currency} balance is used",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item.family,
        account_provider: enable_banking_account.account_provider,
        metadata: {
          enable_banking_item_id: enable_banking_item.id,
          enable_banking_account_id: enable_banking_account.id,
          uid: enable_banking_account.uid,
          currency: currency,
          other_balances: funded
        }
      )
    end

    # The flag only changes how a credit card's balance is read (see
    # EnableBankingAccount::Processor#process_account!), so any other linked
    # account stays booked-first even if the flag is still set from an earlier link.
    def prefer_available_balance?(enable_banking_account)
      enable_banking_account.treat_balance_as_available_credit? &&
        enable_banking_account.current_account&.accountable_type == "CreditCard"
    end

    # Returns [balance, tiebreak_stage]. tiebreak_stage is nil unless the chosen
    # type was reported more than once (see resolve_same_type_balances).
    def select_current_balance(balances, enable_banking_account, prefer_available: false)
      by_type = balances.group_by { |balance| normalize_balance_type(balance[:balance_type]) }
      priority = prefer_available ? AVAILABLE_CREDIT_BALANCE_TYPE_PRIORITY : BALANCE_TYPE_PRIORITY

      priority.each do |type|
        normalized_type = normalize_balance_type(type)
        candidates = by_type[normalized_type]
        next if candidates.blank?

        if PERIOD_BOUNDARY_TYPES.include?(normalized_type)
          # Checked before the tiebreak, so a tie among OPBD/PRCD entries that a
          # fresher balance replaces anyway is neither resolved nor logged.
          newest = candidates.max_by { |candidate| parse_reference_date(candidate[:reference_date]) || Date.new(0) }
          fresher = fresher_balance(newest, balances)
          if fresher
            # fresher_balance takes the first entry of the newest date, so
            # same-type entries of that date go through the same tiebreak.
            # Older entries of that type still make the pick unverified.
            same_type = by_type[normalize_balance_type(fresher[:balance_type])]
            fresher_date = parse_reference_date(fresher[:reference_date])
            same_day = same_type.select { |candidate| parse_reference_date(candidate[:reference_date]) == fresher_date }
            fresher, fresher_stage = resolve_same_type_balances(same_day, enable_banking_account)
            return [ fresher, same_day.size == same_type.size ? fresher_stage : :fresher ]
          end
        end

        return resolve_same_type_balances(candidates, enable_banking_account)
      end

      # No known type: response order decides, which is no evidence once there
      # is more than one entry.
      [ balances.first, balances.one? ? nil : :first ]
    end

    # Some ASPSPs report the same balance_type twice with different amounts, e.g.
    # two CLBD entries where one includes the arranged overdraft (#3188). Stages,
    # strongest evidence first:
    #   :credit_limit               (depository) gap equals the credit limit; lower wins
    #   :last_committed_transaction candidates point to different bookings; newest wins
    #   :anchor / :anchor_timestamp (depository) matches the previous anchor minus
    #                               booked flows since, if that anchor was verified
    #   :lowest                     (depository) an included overdraft only ever raises it
    #   :first                      (other accounts) first entry in response order
    def resolve_same_type_balances(candidates, enable_banking_account)
      return [ candidates.first, nil ] if candidates.one?

      usable = candidates.select { |balance| signed_balance_amount(balance) }
      return [ candidates.first, nil ] if usable.empty?
      return [ usable.first, nil ] if usable.one?
      # The same amount reported twice is no ambiguity.
      return [ usable.first, nil ] if usable.map { |balance| signed_balance_amount(balance) }.uniq.one?

      balance, stage = tiebreak_same_type_balances(usable, enable_banking_account)
      capture_balance_tiebreak_debug_log(enable_banking_account, candidates, balance, stage)
      [ balance, stage ]
    end

    def tiebreak_same_type_balances(candidates, enable_banking_account)
      account = enable_banking_account.current_account
      depository = account&.accountable_type == "Depository"

      # A gap equal to the arranged overdraft is direct evidence of #3188, so it
      # decides before the booking references, which say nothing about overdrafts.
      if depository
        winner = balance_by_credit_limit(candidates, enable_banking_account)
        return [ winner, :credit_limit ] if winner
      end

      booked = booked_raw_transactions(enable_banking_account)
      winner = balance_by_last_committed_transaction(candidates, booked)
      return [ winner, :last_committed_transaction ] if winner

      return [ candidates.first, :first ] unless depository

      winner, stage = balance_by_anchor(candidates, enable_banking_account, account, booked)
      return [ winner, stage ] if winner

      [ candidates.min_by { |balance| signed_balance_amount(balance) }, :lowest ]
    end

    # last_committed_transaction is the entry_reference of the last booking the
    # balance includes. Only decides when every candidate points to a different,
    # known booking; equal references say nothing about which amount is right.
    def balance_by_last_committed_transaction(candidates, booked)
      references = candidates.map { |balance| balance[:last_committed_transaction].presence }
      return nil if references.any?(&:nil?) || references.uniq.size != references.size

      # A reference reused with different dates cannot say which booking is
      # newer, and this stage counts as verified, so such a reference abstains.
      booking_dates = booked.each_with_object({}) do |tx, dates|
        reference = tx[:entry_reference].presence
        date = raw_transaction_date(tx)
        (dates[reference] ||= Set.new) << date if reference && date
      end

      dates = references.map { |reference| booking_dates[reference] }
      return nil unless dates.all? { |reference_dates| reference_dates&.one? }

      dated = candidates.zip(dates.map(&:first))

      latest = dated.map(&:last).max
      newest = dated.select { |_, date| date == latest }
      newest.one? ? newest.first.first : nil
    end

    # An arranged overdraft counted into one of the balances shifts it up by the
    # credit limit, so a gap matching the limit identifies the lower one as real.
    def balance_by_credit_limit(candidates, enable_banking_account)
      credit_limit = enable_banking_account.credit_limit
      return nil unless credit_limit.present? && credit_limit.positive?

      amounts = candidates.map { |balance| signed_balance_amount(balance) }
      return nil unless ((amounts.max - amounts.min) - credit_limit).abs <= BALANCE_TIEBREAK_TOLERANCE

      candidates.min_by { |balance| signed_balance_amount(balance) }
    end

    # Expected balance = previous anchor minus booked flows since (asset account,
    # positive amount = outflow, mirroring Balance::ForwardCalculator). Skipped
    # unless the current anchor was verified when it was written: an anchor that
    # already came from the wrong candidate would otherwise confirm itself.
    #
    # Bookings dated on the anchor day may or may not be in the anchor (it was
    # taken at some point that day), so the expectation is computed both ways and
    # only an answer both agree on counts.
    def balance_by_anchor(candidates, enable_banking_account, account, booked)
      return nil unless enable_banking_account.balance_verified? && account.has_current_anchor?
      return nil unless anchor_written_by_this_link?(account, enable_banking_account)

      anchor_date = account.current_anchor_date
      flows = booked.map { |tx| [ raw_transaction_date(tx), tx ] }
      # A booking without a usable date may fall after the anchor: abstain.
      return nil if flows.any? { |date, _| date.nil? }

      dated = flows.filter_map do |date, tx|
        [ date, signed_transaction_amount(tx) ] if date >= anchor_date && date <= Date.current
      end
      # An unparseable amount makes the expected balance unknowable: abstain.
      return nil if dated.any? { |_, amount| amount.nil? }
      later_flows = dated.sum { |date, amount| date > anchor_date ? amount : 0 }
      all_flows = dated.sum { |_, amount| amount }

      closest = matching_balances(candidates, account.current_anchor_balance - later_flows)
      return nil if closest.empty?
      return nil unless closest == matching_balances(candidates, account.current_anchor_balance - all_flows)
      return [ closest.first, :anchor ] if closest.one?

      latest = closest.filter_map { |balance| [ balance, parse_balance_timestamp(balance[:last_change_date_time]) ] }
        .select { |_, time| time }
      return nil unless latest.size == closest.size

      newest_time = latest.map(&:last).max
      newest = latest.select { |_, time| time == newest_time }
      newest.one? ? [ newest.first.first, :anchor_timestamp ] : nil
    end

    # balance_verified lives on the provider account, so after a relink it would
    # otherwise vouch for an anchor the new account got elsewhere.
    def anchor_written_by_this_link?(account, enable_banking_account)
      linked_at = enable_banking_account.account_provider&.created_at
      anchor_written_at = account.valuations.current_anchor.joins(:entry).pick(Arel.sql("entries.updated_at"))
      linked_at.present? && anchor_written_at.present? && anchor_written_at >= linked_at
    end

    # Only candidates that actually match the expectation count: the closest of
    # several far-off amounts is no evidence for any of them.
    def matching_balances(candidates, expected)
      candidates.select { |balance| (signed_balance_amount(balance) - expected).abs <= BALANCE_TIEBREAK_TOLERANCE }
    end

    # Same dates as the entries get (EnableBankingEntry::Processor#date); nil
    # when the row has no usable date.
    def raw_transaction_date(tx)
      return nil if tx.values_at(:booking_date, :value_date, :transaction_date).all?(&:blank?)

      EnableBankingEntry::Processor.transaction_date(tx, enable_banking_item.family.timezone)
    rescue ArgumentError, TypeError
      nil
    end

    def booked_raw_transactions(enable_banking_account)
      enable_banking_account.raw_transactions_payload.to_a.map(&:with_indifferent_access).select do |tx|
        tx[:status] != "PDNG" && !tx[:_pending] && !tx.dig(:extra, :enable_banking, :pending) &&
          !EnableBankingEntry::Processor.unidentified_hold?(tx)
      end
    end

    # Same sign convention as EnableBankingEntry::Processor#amount_value:
    # DBIT (outflow) positive, CRDT (inflow) negative.
    def signed_transaction_amount(tx)
      amount = tx.dig(:transaction_amount, :amount) || tx[:amount]
      absolute = BigDecimal(amount.to_s).abs
      tx[:credit_debit_indicator] == "CRDT" ? -absolute : absolute
    rescue ArgumentError, TypeError
      nil
    end

    def signed_balance_amount(balance)
      amount = balance.dig(:balance_amount, :amount) || balance[:amount]
      return nil if amount.blank?

      parsed = BigDecimal(amount.to_s)
      balance[:credit_debit_indicator].to_s.upcase == "DBIT" ? -parsed : parsed
    rescue ArgumentError, TypeError
      nil
    end

    def parse_balance_timestamp(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Banks that always report the duplicate would otherwise add the same warning
    # on every sync; log again only when the candidates or the outcome change.
    # Amounts, not positions, so a bank reordering the same entries stays quiet.
    def capture_balance_tiebreak_debug_log(enable_banking_account, candidates, chosen, stage)
      amount_key = ->(balance) { signed_balance_amount(balance)&.to_s("F").to_s }
      fingerprint = Digest::SHA256.hexdigest(
        [ stage, amount_key.call(chosen), candidates.map(&amount_key).sort ].to_json
      )
      return if last_balance_tiebreak_fingerprint(enable_banking_account) == fingerprint

      DebugLogEntry.capture(
        category: "provider_sync_warning",
        level: "warn",
        message: "Enable Banking reported the same balance type more than once; resolved by #{stage}",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item.family,
        account_provider: enable_banking_account.account_provider,
        metadata: {
          enable_banking_item_id: enable_banking_item.id,
          enable_banking_account_id: enable_banking_account.id,
          balance_type: chosen[:balance_type],
          stage: stage.to_s,
          fingerprint: fingerprint,
          chosen_index: candidates.index(chosen),
          previous_balance_verified: enable_banking_account.balance_verified?,
          credit_limit: enable_banking_account.credit_limit&.to_s("F"),
          candidates: candidates.map do |balance|
            {
              amount: balance.dig(:balance_amount, :amount) || balance[:amount],
              currency: balance_currency(balance),
              credit_debit_indicator: balance[:credit_debit_indicator],
              last_change_date_time: balance[:last_change_date_time],
              reference_date: balance[:reference_date],
              last_committed_transaction: balance[:last_committed_transaction].present?
            }
          end
        }
      )
    end

    def last_balance_tiebreak_fingerprint(enable_banking_account)
      account_provider = enable_banking_account.account_provider
      return nil unless account_provider

      DebugLogEntry
        .where(account_provider: account_provider, category: "provider_sync_warning", source: self.class.name)
        .order(created_at: :desc, id: :desc)
        .first&.metadata&.dig("fingerprint")
    end

    # Guards the OPBD/PRCD priority (see BALANCE_TYPE_PRIORITY) against picking a
    # stale period-boundary snapshot when the same response also carries a balance
    # with a strictly newer `reference_date` — an optional Enable Banking field, so
    # absence on either side just skips the check rather than treating it as older.
    def fresher_balance(period_boundary_balance, balances)
      reference_date = parse_reference_date(period_boundary_balance[:reference_date])
      return nil unless reference_date

      balances
        .select { |balance| FRESHNESS_BALANCE_TYPES.include?(normalize_balance_type(balance[:balance_type])) }
        .filter_map { |balance| [ balance, parse_reference_date(balance[:reference_date]) ] }
        .select { |_, date| date && date > reference_date }
        .max_by { |_, date| date }
        &.first
    end

    def parse_reference_date(value)
      return nil if value.blank?
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_balance_type(type)
      type.to_s.delete("_-").downcase
    end

    def mark_balance_unavailable(enable_banking_account)
      unless enable_banking_account.persisted?
        enable_banking_account.current_balance = nil
        return
      end

      enable_banking_account.update_columns(
        current_balance: nil,
        updated_at: Time.current
      )
    end

    def capture_balance_sync_error(enable_banking_account, error)
      metadata = {
        enable_banking_item_id: enable_banking_item.id,
        enable_banking_account_id: enable_banking_account.id,
        uid: enable_banking_account.uid,
        api_account_id: enable_banking_account.api_account_id,
        previous_current_balance: enable_banking_account.current_balance,
        error_class: error.class.name,
        error_message: sanitized_error_message(error)
      }

      if error.is_a?(Provider::EnableBanking::EnableBankingError)
        metadata[:error_type] = error.error_type.to_s
        metadata[:provider_error] = sanitized_provider_error(error)
      end

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Failed to fetch Enable Banking balance; keeping previous balance and continuing transaction sync",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item.family,
        account_provider: enable_banking_account.account_provider,
        metadata: metadata
      )
    end

    # Surfaces a pagination truncation as a support-visible diagnostic (rather than
    # only a Rails log line) so the /settings/debug UI shows when a sync silently
    # dropped pages beyond a validation error, in case the account ever has more
    # transactions in the requested window than the ASPSP's broken pagination can
    # actually deliver (currently harmless for narrow incremental sync windows, but
    # a wider historical resync could otherwise lose data without any visible sign).
    def capture_pagination_truncation_debug_log(enable_banking_account, transaction_status:, pages_kept:, transactions_kept:, error:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Enable Banking transaction pagination truncated by a validation error mid-fetch; kept partial results instead of failing the sync",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item.family,
        account_provider: enable_banking_account.account_provider,
        metadata: {
          enable_banking_item_id: enable_banking_item.id,
          enable_banking_account_id: enable_banking_account.id,
          uid: enable_banking_account.uid,
          transaction_status: transaction_status,
          pages_kept: pages_kept,
          transactions_kept: transactions_kept,
          error_type: error.error_type.to_s,
          provider_error: sanitized_provider_error(error)
        }
      )
    end

    # A strategy=longest fetch that stops at the page cap or on a repeated
    # continuation key keeps its rows and is not retried, so the missing
    # history is surfaced here.
    def capture_longest_truncation_debug_log(enable_banking_account, transactions_kept:, reason:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Enable Banking strategy=longest transaction fetch stopped early; kept partial history",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item.family,
        account_provider: enable_banking_account.account_provider,
        metadata: {
          enable_banking_item_id: enable_banking_item.id,
          enable_banking_account_id: enable_banking_account.id,
          uid: enable_banking_account.uid,
          transactions_kept: transactions_kept,
          reason: reason
        }
      )
    end

    # Surfaces "ASPSP doesn't support PDNG" as a support-visible diagnostic, same
    # rationale as capture_pagination_truncation_debug_log: this is a partial
    # degradation (booked transactions still sync, pending transactions are
    # silently skipped) that was previously only visible via Rails.logger.
    def capture_pdng_unsupported_debug_log(enable_banking_account, error:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "ASPSP does not support the PDNG transaction status; skipping pending transactions and continuing with booked transactions only",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item.family,
        account_provider: enable_banking_account.account_provider,
        metadata: {
          enable_banking_item_id: enable_banking_item.id,
          enable_banking_account_id: enable_banking_account.id,
          uid: enable_banking_account.uid,
          error_type: error.error_type.to_s,
          provider_error: sanitized_provider_error(error)
        }
      )
    end

    def sanitized_error_message(error)
      return error.message unless error.is_a?(Provider::EnableBanking::EnableBankingError)

      provider_error = sanitized_provider_error(error)
      provider_error[:message].presence ||
        provider_error[:error].presence ||
        provider_error[:error_type].presence ||
        error.error_type.to_s
    end

    def sanitized_provider_error(error)
      response_data = error.response_data
      response_data = response_data.with_indifferent_access if response_data.respond_to?(:with_indifferent_access)

      metadata = { error_type: error.error_type.to_s }
      return metadata unless response_data.is_a?(Hash)

      metadata[:code] = response_data[:code] if response_data[:code].present?
      metadata[:error] = response_data[:error] if response_data[:error].present?
      metadata[:message] = response_data[:message] if response_data[:message].present?

      detail = response_data[:detail]
      detail = detail.with_indifferent_access if detail.respond_to?(:with_indifferent_access)

      if detail.is_a?(Hash)
        metadata[:detail_message] = detail[:message] if detail[:message].present?
        metadata[:detail_error_name] = detail[:error_name] if detail[:error_name].present?
      end

      metadata
    end

    def promote_session_invalid(existing, new)
      return new if existing.nil?
      return new if new == I18n.t("enable_banking_items.errors.session_invalid")
      existing
    end

    def include_pending?
      Setting.syncs_include_pending
    end

    def fetch_and_store_transactions(enable_banking_account)
      first_fetch = first_transactions_fetch?(enable_banking_account)
      start_date = determine_sync_start_date(enable_banking_account)
      include_pending = include_pending?

      all_transactions, book_truncated, book_window_start = fetch_paginated_transactions(
        enable_banking_account,
        start_date: start_date,
        transaction_status: "BOOK",
        psu_headers: enable_banking_item.build_psu_headers,
        strategy: first_fetch ? "longest" : nil
      )
      truncated = first_fetch && book_truncated
      if truncated
        Rails.logger.warn "EnableBankingItem::Importer - strategy=longest fetch for account #{enable_banking_account.uid} was cut short; the stored history may be incomplete"
      end

      if include_pending
        # Tag any transaction in all_transactions (fetched as BOOK but actually PDNG or an unidentified hold) with _pending: true
        all_transactions = all_transactions.map do |tx|
          tx_ia = tx.with_indifferent_access
          is_pending = tx_ia[:status] == "PDNG" || EnableBankingEntry::Processor.unidentified_hold?(tx_ia)
          is_pending ? tx_ia.merge(_pending: true) : tx_ia
        end
      else
        # If include_pending is false, we must filter out any pending transactions
        # that were returned (e.g. if the bank ignores transaction_status="BOOK" or returns unfinalized holds).
        all_transactions = all_transactions.reject do |tx|
          tx_ia = tx.with_indifferent_access
          tx_ia[:status] == "PDNG" || EnableBankingEntry::Processor.unidentified_hold?(tx_ia)
        end
      end

      pending_transactions = []
      pending_truncated = false
      pending_window_start = nil
      if include_pending
        # Also fetch pending transactions (visible for 1-3 days before they become BOOK) if setting is enabled.
        # Some ASPSPs refuse PDNG with either a 400 or 422. Keep syncing booked rows
        # and retain stored pending rows when the pending fetch was refused.
        begin
          # Pending rows are only a few days old, so a first fetch without a
          # start date still sends a short, explicit window here.
          pending_start_date = start_date || 30.days.ago.to_date
          pending_transactions, pending_truncated, pending_window_start = fetch_paginated_transactions(
            enable_banking_account,
            start_date: pending_start_date,
            transaction_status: "PDNG",
            psu_headers: enable_banking_item.build_psu_headers
          )
          pending_window_start ||= pending_start_date
        rescue Provider::EnableBanking::EnableBankingError => e
          raise unless [ :validation_error, :bad_request ].include?(e.error_type)
          api_error = e.response_data.is_a?(Hash) ? (e.response_data[:error] || e.response_data["error"]) : nil
          pending_truncated = true
          Rails.logger.warn "EnableBankingItem::Importer - ASPSP does not support PDNG transaction status for account #{enable_banking_account.uid}, skipping pending transactions. API error: #{api_error || e.message}"
          capture_pdng_unsupported_debug_log(enable_banking_account, error: e)
        end
      end

      booked_transactions = all_transactions.reject { |tx| tx.with_indifferent_access[:_pending] }

      book_fingerprints = booked_transactions
        .map { |tx| EnableBankingEntry::Processor.compute_external_id(tx) }
        .compact.to_set

      # Also index all booked entry_references so a pending row that lacks
      # transaction_id can still be matched when the settled BOOK row adds one
      # (fingerprints differ; entry_reference stays the same across settlement).
      book_entry_refs = booked_transactions
        .map { |tx| tx.with_indifferent_access[:entry_reference].presence }
        .compact.to_set

      pending_transactions.reject! do |tx|
        tx_ia = tx.with_indifferent_access
        fp = EnableBankingEntry::Processor.compute_external_id(tx_ia)
        entry_ref = tx_ia[:entry_reference].presence
        (fp.present? && book_fingerprints.include?(fp)) ||
          (entry_ref.present? && book_entry_refs.include?(entry_ref))
      end

      all_transactions = all_transactions + tag_as_pending(pending_transactions)

      # Deduplicate API response: Enable Banking sometimes returns the same logical
      # transaction with different entry_reference IDs in the same response.
      # Remove content-level duplicates before storing. (Issue #954)
      all_transactions = deduplicate_api_transactions(all_transactions)

      # Post-fetch safety filter: some ASPSPs ignore date_from or return extra transactions
      all_transactions = filter_transactions_by_date(all_transactions, start_date)

      transactions_count = all_transactions.count

      stored_payload = enable_banking_account.raw_transactions_payload.as_json
      existing_transactions = enable_banking_account.raw_transactions_payload.to_a.dup

      removed_pending = false

      unless include_pending
        removed_pending = existing_transactions.reject! { |tx| pending_row?(tx) }
      end

      if all_transactions.any?

        # C4: Remove stored PDNG entries that have now settled as BOOK.
        # Two match strategies run in parallel:
        # 1. Fingerprint: covers same-ID rows and ID-less rows matched by content.
        # 2. Entry-reference cross-match: covers the case where a pending row had
        #    no transaction_id but the settled BOOK row gained one — fingerprints
        #    diverge (enable_banking_<ref> vs enable_banking_<txn_id>) but the
        #    shared entry_reference is a reliable settlement signal.
        booked_transactions_for_settlement = all_transactions.reject { |tx| tx.with_indifferent_access[:_pending] }

        book_fingerprints = booked_transactions_for_settlement
          .map { |tx| EnableBankingEntry::Processor.compute_external_id(tx) }
          .compact.to_set

        book_entry_refs = booked_transactions_for_settlement
          .map { |tx| tx.with_indifferent_access[:entry_reference].presence }
          .compact.to_set

        if include_pending
          removed_pending ||= existing_transactions.reject! do |tx|
            tx = tx.with_indifferent_access
            next false unless pending_row?(tx)

            fp = EnableBankingEntry::Processor.compute_external_id(tx)
            entry_ref = tx[:entry_reference].presence
            (fp.present? && book_fingerprints.include?(fp)) ||
              (entry_ref.present? && book_entry_refs.include?(entry_ref))
          end
        end

        windows = { false => { start: book_window_start || start_date, complete: !book_truncated } }
        windows[true] = { start: pending_window_start, complete: !pending_truncated } if include_pending

        in_window, retained_transactions = existing_transactions.partition do |tx|
          window = windows[pending_row?(tx)]
          window && in_fetched_window?(tx, window[:start])
        end

        # A truncated fetch cannot show that an unfetched row is gone, only that a
        # fetched row is the same movement as a stored one.
        ids_by_row = external_ids_by_row(existing_transactions + all_transactions)
        superseded_rows, partial_rows = in_window.partition { |tx| windows[pending_row?(tx)][:complete] }
        paired = content_pairs(partial_rows, all_transactions, ids_by_row, ids_by_row).map(&:first)
        paired_set = Set.new.compare_by_identity.merge(paired)
        superseded_rows += paired
        retained_transactions += partial_rows.reject { |tx| paired_set.include?(tx) }

        next_snapshot, incoming_transactions = merge_transaction_rows(
          existing_transactions, retained_transactions, all_transactions, ids_by_row
        )

        if removed_pending || next_snapshot.as_json != existing_transactions.as_json
          # The re-keys and the snapshot they describe commit or roll back together.
          write_snapshot_unless_changed(enable_banking_account, stored_payload) do
            rekey_rotated_identifiers!(
              enable_banking_account, existing_transactions, next_snapshot, superseded_rows, incoming_transactions
            )

            enable_banking_account.upsert_enable_banking_transactions_snapshot!(next_snapshot)
          end
        end
      elsif removed_pending
        write_snapshot_unless_changed(enable_banking_account, stored_payload) do
          enable_banking_account.upsert_enable_banking_transactions_snapshot!(existing_transactions)
        end
      end

      # A completed first fetch always leaves a payload, even an empty one, so
      # the next fetch is incremental (nil means "never fetched").
      if enable_banking_account.raw_transactions_payload.nil?
        enable_banking_account.upsert_enable_banking_transactions_snapshot!([])
      end

      { success: true, transactions_count: transactions_count, truncated: truncated }
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "EnableBankingItem::Importer - Error fetching transactions for account #{enable_banking_account.uid}: #{e.message}"
      { success: false, transactions_count: 0, error: handle_sync_error(e) }
    rescue => e
      Rails.logger.error "EnableBankingItem::Importer - Unexpected error fetching transactions for account #{enable_banking_account.uid}: #{e.class} - #{e.message}"
      { success: false, transactions_count: 0, error: handle_sync_error(e) }
    end

    # Collapse rows the API returns more than once for the same movement.
    #
    # Two real same-day payments, with no transaction_id or a shared one (it is
    # not guaranteed unique), can match on every content field and differ only
    # in entry_reference, which Enable Banking documents as the per-account
    # identifier of a booked entry. Booked rows with distinct references
    # therefore stay apart, while pending and reference-less copies of the same
    # content still collapse into them.
    def deduplicate_api_transactions(transactions)
      reference_groups = transactions.each_with_object(Set.new) do |tx, groups|
        tx = tx.with_indifferent_access
        groups.add(build_transaction_content_key(tx)) if distinct_booked_reference?(tx)
      end

      seen = {}
      duplicates_removed = 0

      result = transactions.select do |tx|
        tx = tx.with_indifferent_access
        key = build_transaction_content_key(tx)

        if reference_groups.include?(key)
          # Prefer booked rows over their otherwise identical pending/ID-less
          # copies, regardless of which appears first in the response.
          unless distinct_booked_reference?(tx)
            duplicates_removed += 1
            next false
          end
          key = [ key, tx[:entry_reference] ]
        end

        if seen[key]
          duplicates_removed += 1
          false
        else
          seen[key] = true
          true
        end
      end

      if duplicates_removed > 0
        Rails.logger.info(
          "EnableBankingItem::Importer - Removed #{duplicates_removed} content-level " \
          "duplicate(s) from API response (#{transactions.count} → #{result.count} transactions)"
        )
      end

      result
    end

    def distinct_booked_reference?(tx)
      tx[:entry_reference].present? && !EnableBankingEntry::Processor.pending_payload?(tx)
    end

    # Build the content key for deduplication. Different entry_reference values
    # can share it; deduplicate_api_transactions decides whether they stay apart.
    # transaction_id is included as one component — not a standalone key —
    # because the Enable Banking API docs state it is not guaranteed to be
    # unique. credit_debit_indicator (CRDT/DBIT) is included because
    # transaction_amount.amount is always positive — without it, a payment
    # and a same-day refund of the same amount would produce identical keys.
    # status (BOOK/PDNG) is intentionally excluded: the same logical transaction
    # may appear as PDNG then BOOK across imports and must not create duplicates.
    # Identical real operations share this key; their booked references tell
    # them apart (EnableBankingEntry::Processor.external_ids_for gives rows
    # sharing a transaction_id their own ids).
    def build_transaction_content_key(tx)
      date = tx[:booking_date].presence || tx[:value_date].presence || tx[:transaction_date]
      amount = tx.dig(:transaction_amount, :amount).presence || tx[:amount]
      currency = tx.dig(:transaction_amount, :currency).presence || tx[:currency]
      creditor = tx.dig(:creditor, :name).presence || tx[:creditor_name]
      debtor = tx.dig(:debtor, :name).presence || tx[:debtor_name]
      remittance = tx[:remittance_information]
      remittance_key = remittance.is_a?(Array) ? remittance.compact.map(&:to_s).sort.join("|") : remittance.to_s
      tid = tx[:transaction_id]
      direction = tx[:credit_debit_indicator]

      [ date, amount, currency, creditor, debtor, remittance_key, tid, direction ].map(&:to_s).join("\x1F")
    end

    class PaginationTruncatedError < StandardError; end

    # Returns the rows fetched, whether the fetch stopped before the last page
    # (page cap, repeated continuation key, or a 400/422 on a later page), and
    # the date_from the ASPSP actually served, which can be later than start_date.
    def fetch_paginated_transactions(enable_banking_account, start_date:, transaction_status:, psu_headers: {}, strategy: nil)
      all_transactions = []
      truncated = false
      window_start = start_date
      continuation_key = nil
      previous_continuation_key = nil
      page_count = 0
      max_pages = strategy.present? ? MAX_LONGEST_PAGINATION_PAGES : MAX_PAGINATION_PAGES

      loop do
        page_count += 1

        if page_count > max_pages
          msg = "EnableBankingItem::Importer - Pagination limit exceeded for account #{enable_banking_account.uid} (status=#{transaction_status}). Stopped after #{max_pages} pages."
          raise PaginationTruncatedError, msg
        end

        begin
          transactions_data = enable_banking_provider.get_account_transactions(
            account_id: enable_banking_account.api_account_id,
            date_from: start_date,
            continuation_key: continuation_key,
            transaction_status: transaction_status,
            psu_headers: psu_headers,
            strategy: strategy
          )
        rescue Provider::EnableBanking::EnableBankingError => e
          # Some ASPSPs (e.g. Trade Republic via Enable Banking) issue a continuation_key
          # that their own API then rejects on the next page as mismatched with
          # transaction_status (422 WRONG_REQUEST_PARAMETERS: "transactionStatus in
          # request is not the same as in continuationKey", surfaced as :validation_error;
          # Trade Republic's PDNG fetch specifically surfaces the same underlying issue as
          # a plain 400/:bad_request instead). Failing outright would discard every page
          # already fetched, so once at least one page has succeeded, treat either error
          # type as "pagination exhausted" and keep the partial result — symmetric with the
          # PDNG-unsupported handling below, which already tolerates both types for the same
          # reason. A validation error on the very first page has no prior data to fall back
          # on and is a real failure, so it still propagates.
          # WRONG_TRANSACTIONS_PERIOD is excluded even mid-pagination: it means the
          # date range itself is invalid (already retried once with a corrected
          # date_from in Provider::EnableBanking#get_account_transactions), not that
          # pagination is exhausted, so swallowing it here would silently drop the
          # remaining pages instead of surfacing a retryable failure. (Issue #392)
          raise if ![ :validation_error, :bad_request ].include?(e.error_type) || page_count == 1 || e.wrong_transactions_period?
          # error (not warn): this discards data for any ASPSP/scenario matching this
          # error_type mid-pagination, not just the specific Trade Republic continuationKey
          # mismatch this was written for — worth surfacing prominently in case a future
          # ASPSP hits this path for a genuinely different reason.
          Rails.logger.error "EnableBankingItem::Importer - Validation error mid-pagination for account #{enable_banking_account.uid} (status=#{transaction_status}), keeping #{all_transactions.count} transaction(s) from #{page_count - 1} page(s). #{e.message}"
          capture_pagination_truncation_debug_log(
            enable_banking_account,
            transaction_status: transaction_status,
            pages_kept: page_count - 1,
            transactions_kept: all_transactions.count,
            error: e
          )
          truncated = true
          break
        end

        transactions = transactions_data[:transactions] || []
        all_transactions.concat(transactions)
        window_start = [ window_start, transactions_data[:effective_date_from] ].compact.max

        previous_continuation_key = continuation_key
        continuation_key = transactions_data[:continuation_key]

        if continuation_key.present? && continuation_key == previous_continuation_key
          msg = "EnableBankingItem::Importer - Repeated continuation_key detected for account #{enable_banking_account.uid} (status=#{transaction_status}). Breaking after #{page_count} pages."
          raise PaginationTruncatedError, msg
        end

        break if continuation_key.blank?
      end

      [ all_transactions, truncated, window_start ]
    rescue PaginationTruncatedError => e
      # Log as warning and return collected partial data instead of failing entirely.
      # This ensures accounts with huge history don't lose all synced data.
      Rails.logger.warn(e.message)
      if strategy.present?
        capture_longest_truncation_debug_log(enable_banking_account, transactions_kept: all_transactions.count, reason: e.message)
      end
      [ all_transactions, true, window_start ]
    end

    # Ids are resolved over stored and fetched rows together so rows sharing a
    # transaction_id can still be told apart by entry_reference.
    def external_ids_by_row(rows)
      rows.zip(EnableBankingEntry::Processor.external_ids_for(rows)).to_h
    end

    def merge_transaction_rows(existing_transactions, retained_transactions, fetched_transactions, ids_by_row)
      retained_ids = retained_transactions.map { |row| ids_by_row[row] }.compact.to_set
      incoming_transactions = fetched_transactions.select do |row|
        id = ids_by_row[row]
        id.present? && !retained_ids.include?(id)
      end

      stored_positions = existing_transactions.map { |row| ids_by_row[row] }.each_with_index.to_h
      snapshot = (retained_transactions + incoming_transactions).sort_by.with_index do |row, index|
        [ stored_positions.fetch(ids_by_row[row], existing_transactions.size), index ]
      end
      [ snapshot, incoming_transactions ]
    end

    def filter_transactions_by_date(transactions, start_date)
      return transactions unless start_date

      transactions.reject do |tx|
        date = row_date(tx)
        date.present? && date < start_date
      end
    end

    # Pairs stored rows with fetched rows describing the same movement. A row that
    # kept its id pairs with itself first, so a reordered response cannot hand one
    # movement's id to another; the rest pair by position, keeping multiplicity.
    def content_pairs(stored_rows, fetched_rows, stored_ids, fetched_ids)
      fetched_by_content = fetched_rows.group_by { |row| content_key(row) }

      stored_rows.group_by { |row| content_key(row) }.flat_map do |key, old_rows|
        new_rows = key && fetched_by_content[key]
        next [] unless new_rows

        unpaired_new = new_rows.dup
        unchanged = []
        rotated = []
        old_rows.each do |old_row|
          old_id = stored_ids[old_row]
          index = old_id.present? && unpaired_new.index { |row| fetched_ids[row] == old_id }
          index ? unchanged << [ old_row, unpaired_new.delete_at(index) ] : rotated << old_row
        end

        unchanged + rotated.zip(unpaired_new).select { |_old_row, new_row| new_row }
      end
    end

    def content_key(transaction)
      content_id = EnableBankingEntry::Processor.compute_external_id(
        transaction.with_indifferent_access.except(:transaction_id, :entry_reference)
      )
      [ pending_row?(transaction), content_id ] if content_id.present?
    end

    # Points existing entries at the ids the ASPSP now uses for the same
    # movements, so the processor updates them (keeping category, merchant,
    # notes and transfer links) instead of inserting beside them.
    def rekey_rotated_identifiers!(enable_banking_account, existing_transactions, next_snapshot, superseded_rows, fetched_rows)
      account = enable_banking_account.current_account
      return if account.blank? || superseded_rows.empty?

      processor = EnableBankingEntry::Processor
      old_ids = existing_transactions.zip(processor.external_ids_for(existing_transactions, account: account)).to_h
      new_ids = next_snapshot.zip(processor.external_ids_for(next_snapshot, account: account)).to_h

      renames = content_pairs(superseded_rows, fetched_rows, old_ids, new_ids).filter_map do |old_row, new_row|
        old_id = old_ids[old_row]
        new_id = new_ids[new_row]
        [ old_id, new_id, new_row ] if old_id.present? && new_id.present? && old_id != new_id
      end
      return if renames.empty?

      entries = account.entries.where(source: "enable_banking")
      taken_ids = entries.where(external_id: renames.map(&:second)).pluck(:external_id).to_set
      entries_by_old_id = entries.where(external_id: renames.map(&:first)).includes(:entryable).lock.index_by(&:external_id)

      renames.each do |old_id, new_id, new_row|
        next if taken_ids.include?(new_id)

        entry = entries_by_old_id[old_id]
        next unless entry && entry.external_id == old_id

        entry.update_column(:external_id, new_id)
        taken_ids << new_id
        if !pending_row?(new_row) && entry.entryable.is_a?(Transaction)
          new_reference = new_row.with_indifferent_access[:entry_reference].to_s.presence
          entry.entryable.update_column(:provider_entry_reference, new_reference)
        end
      end
    end

    # Skips the write when another sync replaced the snapshot after this one read
    # it; re-keying against a stale snapshot would insert a duplicate entry.
    def write_snapshot_unless_changed(enable_banking_account, stored_payload)
      ActiveRecord::Base.transaction do
        enable_banking_account.lock!
        if enable_banking_account.raw_transactions_payload.as_json == stored_payload
          yield
        else
          Rails.logger.info "EnableBankingItem::Importer - snapshot for account #{enable_banking_account.uid} changed during sync, skipping write"
        end
      end
    end

    # Undated rows are kept: they cannot be shown to be superseded.
    def in_fetched_window?(transaction, start_date)
      return true unless start_date

      date = row_date(transaction)
      date.present? && date >= start_date
    end

    # Dated as EnableBankingEntry::Processor dates the entry, in the family's zone.
    def row_date(transaction)
      tx = transaction.with_indifferent_access
      return nil if (tx[:booking_date] || tx[:value_date] || tx[:transaction_date]).blank?

      EnableBankingEntry::Processor.transaction_date(tx, enable_banking_item.family&.timezone)
    rescue ArgumentError, TypeError, RangeError
      nil
    end

    # A row is pending either as stored (extra.enable_banking.pending, written by
    # the processor) or as freshly tagged by tag_as_pending during this fetch.
    def pending_row?(transaction)
      tx = transaction.with_indifferent_access
      pending = tx.dig(:extra, :enable_banking, :pending) || tx[:_pending] || EnableBankingEntry::Processor.unidentified_hold?(tx)
      pending ? true : false
    end

    def tag_as_pending(transactions)
      transactions.map { |tx| tx.merge(_pending: true) }
    end

    def find_enable_banking_account_by_hash(hash_value)
      return nil if hash_value.blank?

      # First: exact uid match (primary identification_hash)
      account = enable_banking_item.enable_banking_accounts.find_by(uid: hash_value.to_s)
      return account if account

      # Second: search in identification_hashes array (PostgreSQL JSONB contains operator)
      enable_banking_item.enable_banking_accounts
        .where("identification_hashes @> ?", [ hash_value.to_s ].to_json)
        .first
    end

    def sync_uids_from_accounts_data(accounts_data)
      return if accounts_data.blank?

      accounts_data.each do |ad|
        next unless ad.is_a?(Hash)
        ad = ad.with_indifferent_access
        identification_hash = ad[:identification_hash]
        current_uid = ad[:uid]
        next if identification_hash.blank? || current_uid.blank?

        eb_acc = find_enable_banking_account_by_hash(identification_hash)
        next unless eb_acc
        # Update the API account_id (UUID) if it has changed (UIDs are session-scoped)
        eb_acc.update!(account_id: current_uid) if eb_acc.account_id != current_uid
      end
    end

    # nil means this account's transactions were never fetched. A completed
    # fetch always stores an array, even an empty one.
    def first_transactions_fetch?(enable_banking_account)
      enable_banking_account.raw_transactions_payload.nil?
    end

    def determine_sync_start_date(enable_banking_account)
      if first_transactions_fetch?(enable_banking_account)
        # The first fetch asks for strategy=longest. The user's start date, when
        # set, is the lower bound (never after today); without one the ASPSP
        # returns all it allows.
        [ enable_banking_item.sync_start_date, Date.current ].min if enable_banking_item.sync_start_date
      else
        incremental_sync_start_date(enable_banking_account)
      end
    end

    # 7 days before the older of the last completed sync and the newest stored
    # row. The stored rows cover an account that was not fetched while the item
    # kept syncing (for example linked again after being unlinked, or linked to
    # an existing account), so its incremental fetch doesn't leave a gap. The
    # stored-row term never goes past STORED_ROW_LOOKBACK_LIMIT, overlap
    # included, so a dormant account doesn't ask for more than the ASPSP serves
    # without SCA on every sync. An account with no stored rows has no anchor,
    # so it uses that limit. The last-sync term is not clamped, so a long
    # outage is handled as before. Nothing before the user's start date is
    # requested, and nothing after today.
    def incremental_sync_start_date(enable_banking_account)
      newest_stored = newest_stored_transaction_date(enable_banking_account)
      stored_row_start = [ newest_stored && newest_stored - 7.days, STORED_ROW_LOOKBACK_LIMIT.ago.to_date ].compact.max

      start = [
        enable_banking_item.last_synced_at && (enable_banking_item.last_synced_at.to_date - 7.days),
        stored_row_start
      ].compact.min

      [ [ start, enable_banking_item.sync_start_date ].compact.max, Date.current ].min
    end

    def newest_stored_transaction_date(enable_banking_account)
      newest = enable_banking_account.raw_transactions_payload.to_a.filter_map do |tx|
        tx = tx.with_indifferent_access
        date_str = tx[:booking_date] || tx[:value_date] || tx[:transaction_date]
        Date.parse(date_str.to_s) if date_str.present?
      rescue ArgumentError
        nil
      end.max
    end
end
