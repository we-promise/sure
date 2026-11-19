class TruelayerItem::Importer
  BACKFILL_CHUNK = 365.days

  # The outcome of fetching one account's transactions: the rows, whether
  # the requested range was covered, and the error that cut it short if any.
  History = Struct.new(:transactions, :complete, :error)

  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def import
    result = {
      success: true,
      accounts_updated: 0,
      accounts_created: 0,
      accounts_failed: 0,
      transactions_imported: 0,
      transactions_failed: 0,
      balances_failed: 0
    }

    truelayer_item.with_access_token do |fresh_token|
      @fresh_token = fresh_token

      import_accounts(result)

      backfilling = backfill_history?
      capture_missed_history_window
      backfill_complete = true

      accounts_to_fetch(backfilling).each do |truelayer_account|
        backfill_complete = import_transactions(truelayer_account, result, backfill: backfilling) && backfill_complete
        import_balance(truelayer_account, result)
      end

      # Only a backfill that saw every account and fetched each in full is
      # complete; otherwise the next sync inside the window retries it, and
      # after the window the card offers a reconnect.
      if backfilling && backfill_complete && result[:accounts_failed].zero?
        truelayer_item.update!(history_backfilled_at: Time.current)
      end

      # Keep consent expiry current so the UI can warn before it lapses.
      truelayer_item.refresh_connection_metadata!(@fresh_token.call)
    end

    result[:success] = result.values_at(:accounts_failed, :transactions_failed, :balances_failed).all?(&:zero?)
    result
  end

  private

    def provider
      @provider ||= truelayer_item.truelayer_provider
    end

    # Runs one API call with a token that is valid now. A 401 means the token
    # expired or was revoked between the check and the call: refresh once and
    # retry. If the token TrueLayer just issued is refused too, nothing more
    # this import can do; stop before every remaining request repeats the
    # refresh, and ask for a reconnect.
    def request
      token = @fresh_token.call
      yield token
    rescue Provider::Truelayer::TruelayerError => e
      raise unless e.error_type == :unauthorized

      begin
        yield @fresh_token.call(rejected: token)
      rescue Provider::Truelayer::TruelayerError => retry_error
        raise unless retry_error.error_type == :unauthorized

        raise Provider::Truelayer::TruelayerError.new("TrueLayer refused a freshly issued access token", :token_rejected, status: 401)
      end
    end

    # Straight after consent every account is fetched: that is the only time
    # the full history is available, and the user links accounts afterwards.
    # Otherwise only linked accounts are fetched, to stay within the bank's
    # unattended-access quota.
    def accounts_to_fetch(backfilling)
      scope = truelayer_item.truelayer_accounts.includes(:account_provider)
      scope = scope.joins(:account).merge(Account.visible) unless backfilling
      scope.to_a
    end

    # The full-history backfill runs once per consent, while the bank still
    # releases more than 90 days (see TruelayerItem::FULL_HISTORY_WINDOW).
    def backfill_history?
      truelayer_item.full_history_available? && truelayer_item.history_backfilled_at.nil?
    end

    # The first import after a consent normally starts within seconds. If it
    # started after the bank's window instead, the older history can no
    # longer be fetched: say so once, and the card offers a reconnect.
    def capture_missed_history_window
      return unless truelayer_item.history_backfill_missed? && first_import_since_consent?

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "TrueLayer consent window closed before the first import; older history was not fetched",
        source: self.class.name,
        provider_key: "truelayer",
        family: truelayer_item.family,
        metadata: { truelayer_item_id: truelayer_item.id, last_authorized_at: truelayer_item.last_authorized_at }
      )
    end

    def first_import_since_consent?
      last_synced_at = truelayer_item.last_synced_at
      last_synced_at.nil? || last_synced_at < truelayer_item.last_authorized_at
    end

    # Accounts come from /accounts and cards from /cards, fetched separately
    # so one failing doesn't discard the other. Unlinked ones are stored so
    # the user can set them up; linked ones get fresh metadata.
    def import_accounts(result)
      accounts = fetch_collection(result) { |token| provider.get_accounts(token) }
      cards = fetch_collection(result) { |token| provider.get_cards(token) }
      return if accounts.nil? && cards.nil?

      snapshots = Array(accounts).map { |a| a.merge(kind: "account") } + Array(cards).map { |c| c.merge(kind: "card") }
      truelayer_item.upsert_truelayer_snapshot!(snapshots)

      # The connection's bank name, from /me, reads better than the
      # per-account provider name, which can be a legal name in capitals.
      institution = truelayer_item.institution_name
      names = TruelayerAccount.display_names(snapshots, institution: institution)
      snapshots.each do |snapshot|
        account_id = snapshot[:account_id].to_s
        next if account_id.blank?

        truelayer_account = truelayer_item.truelayer_accounts.find_or_initialize_by(account_id: account_id)
        created = truelayer_account.new_record?
        truelayer_account.upsert_truelayer_snapshot!(snapshot, display_name: names[account_id], institution: institution)
        created ? result[:accounts_created] += 1 : result[:accounts_updated] += 1
      rescue => e
        result[:accounts_failed] += 1
        Rails.logger.error "TruelayerItem::Importer - Failed to store account #{account_id}: #{e.message}"
      end

      prune_vanished_accounts("account", accounts)
      prune_vanished_accounts("card", cards)
    end

    # One collection from the bank: a list, or nil when the provider has no
    # such endpoint or the request failed. A failure counts against the sync;
    # one that needs a reconnect propagates.
    def fetch_collection(result)
      request { |token| yield token }
    rescue Provider::Truelayer::TruelayerError => e
      result[:accounts_failed] += 1
      capture_failure("Failed to fetch TrueLayer accounts", e)
      raise if e.reauth_required?
      nil
    end

    # An unlinked account the bank no longer returns (closed, or dropped from
    # the consent) is removed, so it doesn't keep the connection in "needs
    # setup" forever. Linked accounts are kept with their history. Each kind
    # is pruned only against its own non-empty list, so an unsupported or
    # failed /cards request can't remove known cards.
    def prune_vanished_accounts(kind, snapshots)
      upstream_ids = Array(snapshots).map { |s| s[:account_id].to_s }.compact_blank
      return if upstream_ids.empty?

      truelayer_item.truelayer_accounts.where(account_kind: kind)
        .left_joins(:account_provider).where(account_providers: { id: nil })
        .where.not(account_id: upstream_ids)
        .destroy_all
    end

    # Returns true when the account's transactions were fetched in full, so
    # the caller can record the backfill as complete.
    def import_transactions(truelayer_account, result, backfill:)
      history = if backfill
        fetch_full_history(truelayer_account)
      else
        History.new(fetch_range(truelayer_account, sync_start_for(truelayer_account), Time.current), true, nil)
      end

      truelayer_account.merge_truelayer_transactions!(history.transactions)
      result[:transactions_imported] += history.transactions.size

      if history.error
        result[:transactions_failed] += 1
        capture_failure("TrueLayer history backfill stopped early", history.error, truelayer_account)
      elsif !history.complete
        capture_failure("TrueLayer consent window closed before the history backfill finished", nil, truelayer_account)
      end

      history.complete
    rescue Provider::Truelayer::TruelayerError => e
      result[:transactions_failed] += 1
      capture_failure("Failed to fetch TrueLayer transactions", e, truelayer_account)
      raise if e.reauth_required?
      false
    end

    # Right after consent the bank serves its full history. Walk back a year
    # per request until the bank or TrueLayer declines an older range, which
    # is the end of the available history, the chosen start date is reached,
    # BACKFILL_YEARS are covered, or the consent window closes. Any other
    # failure (rate limit, outage) is returned with the rows fetched so far,
    # so the caller records it rather than treating the partial result as
    # complete.
    def fetch_full_history(truelayer_account)
      deadline = truelayer_item.last_authorized_at + TruelayerItem::FULL_HISTORY_WINDOW
      start = history_start
      to = Time.current
      collected = []

      # The window closed since the decision to backfill: fetch the regular
      # range instead, so this sync still brings in recent transactions.
      if Time.current > deadline
        return History.new(fetch_range(truelayer_account, sync_start_for(truelayer_account), to), false, nil)
      end

      Rails.configuration.x.truelayer.backfill_years.times do |i|
        return History.new(collected, false, nil) if Time.current > deadline

        from = to - BACKFILL_CHUNK
        from = start if start && from < start
        begin
          collected.concat(fetch_range(truelayer_account, from, to))
        rescue Provider::Truelayer::TruelayerError => e
          # The most recent year must work; only an older one may be declined.
          raise if i.zero? || e.reauth_required?
          return History.new(collected, false, e) unless e.history_refused?

          capture_failure("TrueLayer history ends before the requested range", e, truelayer_account, level: "info")
          break
        end
        break if start && from <= start
        to = from
      end

      History.new(collected, true, nil)
    end

    def fetch_range(truelayer_account, from, to)
      return [] if from >= to

      request do |token|
        provider.get_transactions(token, kind: truelayer_account.account_kind, account_id: truelayer_account.account_id, from: from, to: to)
      end
    end

    # From a week before the last sync, never older than unattended access
    # allows (UK banks reject ranges beyond 90 days without the customer) nor
    # than the chosen start date.
    def sync_start_for(truelayer_account)
      floor = [ TruelayerItem::MAX_UNATTENDED_HISTORY_DAYS.days.ago.beginning_of_day, history_start ].compact.max
      return floor if truelayer_account.raw_transactions_payload.blank? || truelayer_item.last_synced_at.nil?

      [ truelayer_item.last_synced_at - 7.days, floor ].max
    end

    # The start date chosen at account setup, or nil for all the bank has.
    def history_start
      truelayer_item.sync_start_date&.beginning_of_day
    end

    def import_balance(truelayer_account, result)
      balance = request { |token| provider.get_balance(token, kind: truelayer_account.account_kind, account_id: truelayer_account.account_id) }
      amount = balance && BigDecimal(balance[:current].to_s, exception: false)
      unless amount&.finite?
        result[:balances_failed] += 1
        capture_failure("TrueLayer returned no usable balance", nil, truelayer_account)
        return
      end

      truelayer_account.apply_balance!(amount, balance[:currency])
    rescue Provider::Truelayer::TruelayerError => e
      result[:balances_failed] += 1
      capture_failure("Failed to fetch TrueLayer balance", e, truelayer_account)
      raise if e.reauth_required?
    end

    def capture_failure(message, error, truelayer_account = nil, level: "warn")
      metadata = { truelayer_item_id: truelayer_item.id }
      metadata[:account_id] = truelayer_account.account_id if truelayer_account
      if error
        metadata[:error_type] = error.error_type
        metadata[:status] = error.status
        metadata[:code] = error.code
        metadata[:error] = error.message
      end

      DebugLogEntry.capture(
        category: "provider_sync",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "truelayer",
        family: truelayer_item.family,
        account_provider: truelayer_account&.account_provider,
        metadata: metadata
      )
      Rails.logger.public_send(level == "info" ? :info : :warn, "TruelayerItem::Importer - #{message}#{": #{error.message}" if error}")
    end
end
