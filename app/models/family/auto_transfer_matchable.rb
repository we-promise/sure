module Family::AutoTransferMatchable
  # The automatic path's cross-currency tolerance when TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE
  # is unset or unusable. 10% is the long-standing default. Real-world FX slippage between
  # a transaction's timestamp and the cached daily rate is typically 1-3%, so an operator
  # seeing coincidental matches on round-number amounts can tighten it without a code change.
  DEFAULT_EXCHANGE_RATE_TOLERANCE = 0.1

  # Beyond this the band stops meaning anything: at 1.0 the lower bound reaches zero and
  # any two cross-currency amounts inside the date window would match.
  MAX_EXCHANGE_RATE_TOLERANCE = 0.5

  # The manual "match as transfer" dialog (Transaction#transfer_match_candidates) is never
  # narrower than this: a user is confirming the match themselves, and FX slippage or
  # card-network markup on a manual-account leg can be wide. Mirrors the same
  # date_window: 30 vs. 4 widening that dialog already applies.
  MANUAL_MATCH_EXCHANGE_RATE_TOLERANCE = 0.1

  # The "Transfer?" hint in the transaction list is unprompted, so it is much
  # narrower than the dialog it opens: across a real multi-currency history,
  # the dialog's 30 days / 10% flagged mostly coincidental small purchases,
  # while 2 days / 3% kept mainly genuine currency conversions.
  TRANSFER_HINT_DATE_WINDOW = 2
  TRANSFER_HINT_EXCHANGE_RATE_TOLERANCE = 0.03

  # Read at call time rather than frozen into a constant at boot, so a bad value falls back
  # instead of raising inside every sync: Family::Syncer and Account::Syncer both call
  # auto_match_transfers! without a tolerance of their own.
  def self.exchange_rate_tolerance
    tolerance = Float(ENV["TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE"], exception: false)
    return DEFAULT_EXCHANGE_RATE_TOLERANCE if tolerance.nil? || !tolerance.finite? || tolerance.negative?

    [ tolerance, MAX_EXCHANGE_RATE_TOLERANCE ].min
  end

  def self.manual_match_exchange_rate_tolerance
    [ MANUAL_MATCH_EXCHANGE_RATE_TOLERANCE, exchange_rate_tolerance ].max
  end

  def transfer_match_candidates(
    date_window: 4,
    exchange_rate_tolerance: Family::AutoTransferMatchable.exchange_rate_tolerance,
    inflow_transaction_id: nil,
    outflow_transaction_id: nil,
    account_id: nil,
    transaction_ids: nil,
    include_rejected: true,
    restrict_cross_currency_to_linked_accounts: false,
    require_common_writer: false,
    exclude_same_wise_item: false
  )
    date_window = coerce_transfer_match_date_window!(date_window)
    exchange_rate_tolerance = coerce_transfer_match_exchange_rate_tolerance!(exchange_rate_tolerance)

    Entry.find_by_sql([
      transfer_match_candidates_sql,
      {
        date_window:,
        family_id: id,
        family_currency: primary_currency_code,
        inflow_transaction_id:,
        outflow_transaction_id:,
        account_id:,
        filter_transaction_ids: !transaction_ids.nil?,
        # IN () is invalid SQL, so an empty list binds a NULL that matches nothing.
        transaction_ids: transaction_ids.presence || [ nil ],
        include_rejected:,
        restrict_cross_currency_to_linked_accounts:,
        require_common_writer:,
        exclude_same_wise_item:,
        lower_exchange_rate_bound: 1 - exchange_rate_tolerance,
        upper_exchange_rate_bound: 1 + exchange_rate_tolerance
      }
    ])
  end

  # Which of `transactions` have a likely transfer counterpart, so the
  # transaction list can point the user to the "match as transfer" dialog.
  #
  # @return [Set<String>] ids of the given transactions that have a candidate
  def transaction_ids_with_transfer_candidates(transactions, user:)
    page_ids = transactions.map(&:id).to_set

    transfer_hint_candidates(transactions, user:).each_with_object(Set.new) do |candidate, ids|
      [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ].each { |id| ids << id if page_ids.include?(id) }
    end
  end

  # Both sides of every pair the "Transfer?" hint offers for any of
  # `transactions`: rows that show the hint once these transactions are free
  # to pair, such as after a match between them was rejected.
  #
  # @return [Set<String>] transaction ids, including ones outside `transactions`
  def transfer_hint_pair_ids(transactions, user:)
    transfer_hint_candidates(transactions, user:).each_with_object(Set.new) do |candidate, ids|
      ids << candidate.inflow_transaction_id << candidate.outflow_transaction_id
    end
  end

  # "Not a transfer" on a hint: rejects every pair the hint offered for this
  # transaction, the same record a rejected auto-match leaves behind, so neither
  # the hint nor the automatic matcher suggests them again. The manual dialog
  # still lists them.
  def dismiss_transfer_hint!(transaction, user:)
    RejectedTransfer.transaction do
      transfer_hint_candidates([ transaction ], user:).each do |candidate|
        RejectedTransfer.find_or_create_by!(
          inflow_transaction_id: candidate.inflow_transaction_id,
          outflow_transaction_id: candidate.outflow_transaction_id
        )
      end
    end
  end

  def auto_match_transfers!(account: nil, exchange_rate_tolerance: Family::AutoTransferMatchable.exchange_rate_tolerance)
    return if auto_match_transfers_disabled?

    # Exclude already matched transfers. Cross-currency FX-tolerance matching is
    # restricted to provider-linked accounts ONLY on this automatic path -- a
    # coincidental amount/FX-rate match applied here has no human reviewing it
    # first. The manual "match as transfer" dialog goes through
    # Transaction#transfer_match_candidates, which calls transfer_match_candidates
    # directly without this restriction, so a user can still find and confirm a
    # real cross-currency transfer that happens to involve a manual account.
    candidates_scope = transfer_match_candidates(
      account_id: account&.id,
      include_rejected: false,
      exchange_rate_tolerance:,
      restrict_cross_currency_to_linked_accounts: true,
      # Only pair accounts that at least one member can write to on both sides, so
      # someone can always confirm or reject the match.
      require_common_writer: true,
      # Two balances of one Wise connection move money between each other only
      # through conversions and Jar moves, which WiseItem#link_jar_transfers!
      # links from Wise's own activity feed. Any other pair across them is a
      # coincidence (a GBP top-up "matching" a USD payout), so it is never
      # suggested here; the manual dialog still offers it.
      exclude_same_wise_item: true
    )

    # Track which transactions we've already matched to avoid duplicates
    used_transaction_ids = Set.new
    created_transfers = []

    Transfer.transaction do
      # Among otherwise equally plausible candidates, a confirmed IBAN match is
      # tried first (see #iban_confirmed_first).
      iban_confirmed_first(candidates_scope).each do |match|
        next if used_transaction_ids.include?(match.inflow_transaction_id) ||
               used_transaction_ids.include?(match.outflow_transaction_id)

        # Skip this candidate when the transfer for this exact pair was not created
        # (a concurrent sync claimed one of the transactions for a different pairing).
        # A created transfer stays pending and leaves the transaction kinds untouched
        # until the user confirms it (Transfer#confirm!).
        transfer = find_or_create_transfer!(match)
        next unless transfer

        created_transfers << transfer if transfer.previously_new_record?
        used_transaction_ids << match.inflow_transaction_id
        used_transaction_ids << match.outflow_transaction_id
      end
    end

    sync_principal_only_loan_accounts(created_transfers)
  end

  # An outflow entry whose counterparty IBAN matches another of this
  # family's accounts (synced or manual) is a transfer whose destination
  # account is known, even though the matching inflow transaction doesn't
  # exist yet -- e.g. the destination is a manually-tracked account the
  # user hasn't recorded this deposit on. Returns that account, or nil when
  # there's nothing to suggest (no counterparty IBAN, no matching account,
  # already a transfer, or the user already dismissed this suggestion).
  #
  # Deliberately entry-scoped rather than family-wide: this only needs to
  # answer "should the transfer-match dialog for THIS entry pre-fill a
  # target account", not enumerate every missing counterpart across the
  # family (no UI surfaces that broader list yet).
  # user: required so the suggested account is restricted to the same
  # writable+visible set TransferMatchesController#new offers in its
  # target_account_id dropdown. Without it, a match on a disabled account or
  # one the current user has no access to (family sharing permissions) would
  # get preselected in the UI despite never appearing among the selectable
  # options -- and would leak that account's name/existence to a user who
  # can't otherwise see it.
  def missing_transfer_suggestion_for(entry, user:)
    return nil unless entry.amount.positive?

    transaction = entry.entryable
    return nil unless transaction.is_a?(Transaction)
    # A pending auto-match leaves the kind untouched until it is confirmed, so
    # the kind alone doesn't tell whether this outflow is already matched.
    return nil if transaction.transfer? || transaction.transfer.present?
    return nil if transaction.extra&.dig("counterparty_transfer_suggestion_dismissed") == true

    counterparty_iban = transaction.counterparty_iban
    return nil if counterparty_iban.blank?

    # One IBAN can back several currency sub-accounts (Revolut, Wise), so
    # prefer the one in the outflow's own currency.
    candidates = accounts.writable_by(user).visible.where.not(id: entry.account_id).where(iban: normalize_iban(counterparty_iban)).to_a
    candidates.find { |candidate| candidate.currency == entry.currency } || candidates.first
  end

  # Family-wide counterpart to missing_transfer_suggestion_for: instead of
  # only answering "what would the match dialog suggest for this one entry",
  # this actually creates the missing counterpart transaction (on the
  # destination account) plus a status: "pending" Transfer linking it to the
  # outflow -- the same pending state auto_match_transfers! leaves behind
  # for a genuine match, so it surfaces via the existing accept/reject pill
  # (transactions/_transfer_match.html.erb) instead of requiring the user to
  # find and open the manual match dialog themselves.
  #
  # Restricted to manual (unsynced) destination accounts only: a linked
  # account's real transaction may simply not have posted yet, and
  # fabricating a stand-in entry for it here would risk a duplicate once the
  # provider's own import brings in the real one. A manual account gets no
  # provider import; when the user later imports the real row from a CSV
  # file, TransactionImport recognises the fabricated entry by account, date,
  # amount and currency and lets the imported row take it over.
  #
  # Currency is intentionally not converted -- only a same-currency
  # destination account is eligible, keeping the fabricated entry's amount
  # exact rather than dependent on same-day exchange-rate availability.
  def auto_create_missing_transfer_counterparts!(account: nil)
    # Only same-currency manual accounts that carry an IBAN can ever receive a
    # fabricated counterpart, so look them up once and skip every outflow whose
    # counterparty IBAN isn't one of theirs (rent, utilities and other third
    # parties) before running any per-entry candidate query.
    target_accounts_by_iban = accounts.visible_manual.to_a
      .select { |target| target.iban.present? }
      .group_by { |target| normalize_iban(target.iban) }
    return if target_accounts_by_iban.empty?

    # Narrow in SQL to outflows that still could need a counterpart: they
    # carry a counterparty IBAN, aren't already a transfer, and the user
    # hasn't dismissed the suggestion.
    outflow_entries = Entry.joins(:account)
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
      .where(accounts: { family_id: id, status: [ "draft", "active" ] })
      .where(entryable_type: "Transaction", excluded: false)
      .where("entries.amount > 0")
      .where.not(transactions: { counterparty_iban: nil })
      .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      .where.not(transactions: { id: Transfer.select(:outflow_transaction_id) })
      .where.not("transactions.extra @> ?", { "counterparty_transfer_suggestion_dismissed" => true }.to_json)
    outflow_entries = outflow_entries.where(account_id: account.id) if account

    writable_account_ids_by_owner = Hash.new do |ids, owner|
      ids[owner] = accounts.writable_by(owner).pluck(:id).to_set
    end

    outflow_entries.preload(:entryable, account: :owner).find_each do |entry|
      transaction = entry.entryable
      next unless transaction.is_a?(Transaction)
      next if transaction.transfer?
      next if transaction.extra&.dig("counterparty_transfer_suggestion_dismissed") == true

      counterparty_iban = transaction.counterparty_iban
      next if counterparty_iban.blank?

      # The sync runs without a user, so act on behalf of the outflow
      # account's owner: only fabricate into an account they could pick in
      # the manual match dialog (TransferMatchesController#new), never into
      # another member's private account. An account without an owner has
      # nobody to act for, so it gets no automatic counterpart (the manual
      # match dialog still works for it).
      owner = entry.account.owner
      next unless owner

      target_account = target_accounts_by_iban[normalize_iban(counterparty_iban)]&.find do |candidate|
        candidate.id != entry.account_id &&
          candidate.currency == entry.currency &&
          writable_account_ids_by_owner[owner].include?(candidate.id)
      end
      next unless target_account

      # A real match candidate (an inflow transaction that already exists)
      # is handled by auto_match_transfers! -- only fabricate a counterpart
      # when there's genuinely nothing to match against yet.
      next if transfer_match_candidates(outflow_transaction_id: transaction.id, account_id: account&.id).any?

      create_missing_transfer_counterpart!(entry, transaction, target_account)
    end
  end

  private
    # Builds the fabricated inflow entry + its pending Transfer in one
    # savepoint, so a race (a concurrent sync claiming this outflow for a
    # different pairing, or creating the same counterpart independently)
    # rolls back the whole attempt instead of leaving an orphaned entry
    # with no Transfer behind it.
    def create_missing_transfer_counterpart!(entry, transaction, target_account)
      created = Transfer.transaction(requires_new: true) do
        # The batch was loaded before this point; the user may have rejected
        # or matched this outflow in the meantime. Re-check under a row lock
        # so a reject during a running sync isn't undone right away.
        transaction.lock!
        next false if transaction.transfer? || Transfer.exists?(outflow_transaction_id: transaction.id)
        next false if transaction.extra&.dig("counterparty_transfer_suggestion_dismissed") == true

        # The fabricated leg is only a stand-in for money that left the
        # outflow account, never real income, so it is a funds movement from
        # the start.
        inflow_transaction = Transaction.new(
          kind: "funds_movement",
          extra: { "auto_generated_transfer_counterpart" => true },
          entry: target_account.entries.build(
            amount: -entry.amount,
            currency: target_account.currency,
            date: entry.date,
            name: I18n.with_locale(locale) { missing_transfer_counterpart_name(entry.account, target_account) }
          )
        )
        inflow_transaction.save!

        Transfer.create!(
          inflow_transaction_id: inflow_transaction.id,
          outflow_transaction_id: transaction.id,
          status: "pending"
        )

        # Like every automatic match, the suggestion leaves the real outflow
        # as it is until the user confirms it (Transfer#confirm! applies the
        # transfer kind), so an unconfirmed suggestion never moves budgets or
        # reports.
        true
      end

      target_account.sync_later if created
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      nil
    end

    # The fabricated entry lives on the target account, so everyone who can
    # see that account reads its name. Name the source account only when all
    # of them can see the source account too; otherwise a private account's
    # name would leak to members it isn't shared with.
    def missing_transfer_counterpart_name(source_account, target_account)
      if account_viewer_ids(target_account).subset?(account_viewer_ids(source_account))
        I18n.t("transfer.counterpart_name", from_account: source_account.name)
      else
        I18n.t("transfer.counterpart_name_generic")
      end
    end

    # The members who can see an account (Account.accessible_by): its owner
    # and everyone it is shared with.
    def account_viewer_ids(account)
      Set.new([ account.owner_id, *account.account_shares.pluck(:user_id) ].compact)
    end

    # Orders the candidates so that IBAN-confirmed ones are tried first. A
    # confirmed IBAN (the destination account's own IBAN equals the outflow's
    # recorded counterparty IBAN) is a more precise signal than amount and date
    # alone, which can be ambiguous with several similar transactions in flight.
    # It only breaks ties: the date window and every other matching rule stay
    # the same, and the resulting transfer is created like any other automatic
    # match. The sort is stable, so inside each group the candidate query's own
    # order (closest date first) still holds.
    def iban_confirmed_first(candidates)
      transaction_ids = candidates.flat_map do |match|
        [ match.inflow_transaction_id, match.outflow_transaction_id ]
      end.uniq
      transactions = Transaction.includes(entry: :account).where(id: transaction_ids).index_by(&:id)

      candidates
        .each_with_index
        .sort_by { |match, index| [ iban_confirmed?(match, transactions) ? 0 : 1, index ] }
        .map(&:first)
    end

    # True when the inflow's destination account has its own IBAN set and it
    # matches the outflow transaction's recorded counterparty IBAN. Blank on
    # either side (no accounts.iban set, or the provider never supplied a
    # counterparty IBAN for this transaction) always resolves to false --
    # this is an additive signal, never a requirement.
    def iban_confirmed?(match, transactions_by_id)
      inflow = transactions_by_id[match.inflow_transaction_id]
      outflow = transactions_by_id[match.outflow_transaction_id]
      return false unless inflow && outflow

      destination_iban = inflow.entry.account.iban
      counterparty_iban = outflow.counterparty_iban
      return false if destination_iban.blank? || counterparty_iban.blank?
      return false unless normalize_iban(destination_iban) == normalize_iban(counterparty_iban)

      # The inflow side's own recorded counterparty IBAN (who the destination
      # account's bank says paid it) is a second, independent signal from the
      # same provider sync. When it's present, it must agree with the source
      # account's IBAN too -- a contradiction here (matching amount/date, but
      # the destination account's bank recorded a DIFFERENT payer) means this
      # is very likely two distinct transactions that merely coincide, not a
      # confirmed transfer. Blank is not a contradiction: not every provider
      # supplies this on the inflow side, so its absence is uninformative.
      source_iban = outflow.entry.account.iban
      inflow_counterparty_iban = inflow.counterparty_iban
      return false if source_iban.present? && inflow_counterparty_iban.present? &&
        normalize_iban(source_iban) != normalize_iban(inflow_counterparty_iban)

      true
    end

    def normalize_iban(value)
      IbanNormalizable.normalize(value).to_s
    end

    # A principal-only loan replays a linked transfer as principal. The balance
    # was materialized before this match existed, so re-sync from the transfer's
    # entry dates.
    def sync_principal_only_loan_accounts(transfers)
      transfers.each do |transfer|
        next unless principal_only_loan_transfer?(transfer)

        transfer.sync_account_later
      end
    end

    def principal_only_loan_transfer?(transfer)
      [ transfer.from_account, transfer.to_account ].compact.any? do |account|
        account.loan? && account.loan.amortizable? && account.loan.principal_only_transfers?
      end
    end

    # The hint's candidate pairs for `transactions`: the narrower hint window and
    # tolerance, no rejected pairs, both legs in the same category (or both
    # uncategorized, since a categorized purchase against an income is not a
    # transfer), and `user` able to write to both accounts
    # (TransferMatchesController#create requires that).
    def transfer_hint_candidates(transactions, user:)
      unmatched_ids = transactions.reject { |transaction| transaction.transfer? || transaction.transfer.present? }.map(&:id)
      return [] if unmatched_ids.empty?

      candidates = transfer_match_candidates(
        date_window: TRANSFER_HINT_DATE_WINDOW,
        exchange_rate_tolerance: TRANSFER_HINT_EXCHANGE_RATE_TOLERANCE,
        transaction_ids: unmatched_ids,
        include_rejected: false
      ).to_a
      return [] if candidates.empty?

      leg_ids = candidates.flat_map { |candidate| [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ] }
      account_ids = Entry.where(entryable_type: "Transaction", entryable_id: leg_ids).pluck(:entryable_id, :account_id).to_h
      category_ids = Transaction.where(id: leg_ids).pluck(:id, :category_id).to_h
      writable_account_ids = accounts.writable_by(user).pluck(:id).to_set

      candidates.select do |candidate|
        inflow_id = candidate.inflow_transaction_id
        outflow_id = candidate.outflow_transaction_id

        category_ids[inflow_id] == category_ids[outflow_id] &&
          writable_account_ids.include?(account_ids[inflow_id]) &&
          writable_account_ids.include?(account_ids[outflow_id])
      end
    end

    # Create the transfer for a matched candidate, tolerating a concurrent sync
    # that already inserted the same pair.
    #
    # The insert runs in its own savepoint (requires_new: true). On PostgreSQL a
    # failed statement aborts the entire surrounding transaction, so rescuing a
    # RecordNotUnique raised by find_or_create_by! is not enough on its own: the
    # next write would fail with PG::InFailedSqlTransaction and the remaining
    # candidates would be silently dropped. Isolating the insert in a savepoint
    # rolls back only the failed statement, leaving the outer transaction healthy.
    def find_or_create_transfer!(match)
      Transfer.transaction(requires_new: true) do
        Transfer.find_or_create_by!(
          inflow_transaction_id: match.inflow_transaction_id,
          outflow_transaction_id: match.outflow_transaction_id,
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # The composite unique index rejected the insert because this exact
      # (inflow, outflow) pair was committed concurrently between our find and our
      # insert. Return that committed row; if it is somehow absent, return nil so the
      # caller skips rather than marking a transaction with no Transfer behind it.
      existing_transfer(match)
    rescue ActiveRecord::RecordInvalid => e
      # The same race surfaces through the per-column uniqueness validation. Re-raise
      # anything that is not a :taken on the transfer's transaction ids...
      raise unless %i[inflow_transaction_id outflow_transaction_id].any? { |attr| e.record.errors.of_kind?(attr, :taken) }
      # ...and even for :taken, only accept it once the exact (inflow, outflow) row is
      # confirmed present; otherwise the :taken came from a different pairing.
      existing_transfer(match)
    end

    # The committed transfer for this exact candidate pair, or nil if none exists.
    def existing_transfer(match)
      Transfer.find_by(
        inflow_transaction_id: match.inflow_transaction_id,
        outflow_transaction_id: match.outflow_transaction_id,
      )
    end

    def coerce_transfer_match_date_window!(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "date_window must be an integer"
    end

    def coerce_transfer_match_exchange_rate_tolerance!(value)
      tolerance = begin
        Float(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "exchange_rate_tolerance must be numeric"
      end

      raise ArgumentError, "exchange_rate_tolerance must be numeric" unless tolerance.finite?
      raise ArgumentError, "exchange_rate_tolerance must be non-negative" if tolerance.negative?

      tolerance
    end

    # A family member who can write to (Account.writable_by) at least one side
    # and to every side that has an owner, so someone can always unlink the
    # match. An owner-less account (owner_id is nullified when its owner is
    # removed from the family) does not block pairing: nobody can write to it,
    # but the member on the other side can still reject the match. When the
    # owner-less side is the outflow, the match can be rejected but not
    # confirmed or edited, as before this condition existed.
    def common_writer_condition_sql
      <<~SQL.squish
        (:require_common_writer = FALSE OR EXISTS (
          SELECT 1 FROM users writers
          WHERE
            writers.family_id = :family_id AND
            (inflow_accounts.owner_id IS NULL OR #{writer_can_write_sql("inflow_accounts")}) AND
            (outflow_accounts.owner_id IS NULL OR #{writer_can_write_sql("outflow_accounts")}) AND
            (#{writer_can_write_sql("inflow_accounts")} OR #{writer_can_write_sql("outflow_accounts")})
        ))
      SQL
    end

    # With :exclude_same_wise_item, drops pairs whose two accounts are linked to
    # balances (WiseAccounts) of the same WiseItem. Applied in both UNION branches,
    # since two balances of one item may share a currency (a balance and its Jar)
    # or not. Only auto_match_transfers! sets it (see the comment there); the
    # manual "match as transfer" dialog leaves it off.
    def same_wise_item_condition_sql
      <<~SQL.squish
        (:exclude_same_wise_item = FALSE OR NOT EXISTS (
          SELECT 1
          FROM account_providers inflow_wise_links
          JOIN wise_accounts inflow_wise_accounts ON inflow_wise_accounts.id = inflow_wise_links.provider_id
          JOIN account_providers outflow_wise_links ON (
            outflow_wise_links.account_id = outflow_accounts.id AND
            outflow_wise_links.provider_type = 'WiseAccount'
          )
          JOIN wise_accounts outflow_wise_accounts ON outflow_wise_accounts.id = outflow_wise_links.provider_id
          WHERE
            inflow_wise_links.account_id = inflow_accounts.id AND
            inflow_wise_links.provider_type = 'WiseAccount' AND
            outflow_wise_accounts.wise_item_id = inflow_wise_accounts.wise_item_id
        ))
      SQL
    end

    # Mirrors Account.writable_by for the `writers` row: owner or full_control share.
    def writer_can_write_sql(accounts_alias)
      <<~SQL.squish
        (writers.id = #{accounts_alias}.owner_id OR EXISTS (
          SELECT 1 FROM account_shares writer_shares
          WHERE writer_shares.account_id = #{accounts_alias}.id AND
            writer_shares.user_id = writers.id AND
            writer_shares.permission = 'full_control'
        ))
      SQL
    end

    # The second UNION branch below (cross-currency, FX-rate-tolerance matching) is a
    # coincidence guess -- amount x FX-rate within a tolerance band, not an exact amount
    # match -- and a manual account has no institution behind it confirming money actually
    # moved, so an unrelated pair of round-number transactions can land inside the tolerance
    # band purely by chance. When :restrict_cross_currency_to_linked_accounts is true, that
    # branch additionally requires both accounts to have a live provider connection
    # (Plaid/SimpleFIN/account_providers). Manual accounts always participate in the first
    # branch's exact-amount, same-currency matching, which carries no such ambiguity.
    # A user-confirmed transfer between the same two accounts, in the same direction,
    # is the exception: it shows money really moves along that route (e.g. a manual
    # RUB wallet that regularly converts into a manual THB account), so cross-currency
    # auto-matching is allowed there too. Auto-matched transfers stay pending until the
    # user confirms them.
    #
    # The restriction is opt-in (default false) rather than baked into the branch
    # unconditionally: Family#auto_match_transfers! passes true because a coincidental match
    # there is applied automatically with no human reviewing it first, but
    # Transaction#transfer_match_candidates (the manual "match as transfer" dialog) leaves it
    # off so a user can still find and confirm a real cross-currency transfer that happens to
    # involve a manual account, rather than being forced into creating a duplicate.
    #
    # The cross-currency branch prefers the direct pair rate. Exchange rates are only
    # synced from each account currency to the family currency, so a transfer between
    # two non-family currencies (e.g. RUB -> THB in a USD family) has no direct rate;
    # the cross rate is then derived through the family currency
    # (RUB -> USD / THB -> USD). The rates are plain LEFT JOINs on the unique
    # (from, to, date) index, so each joins at most one row and the planner can hash
    # them; a missing rate leaves the tolerance check NULL, which drops the pair.
    # A zero direct rate is treated as missing so it cannot mask a usable derived rate.
    #
    # Candidates are ordered by match_rank before date_diff: exact same-currency matches
    # (rank 0) come before FX-tolerance guesses (rank 1). auto_match_transfers! consumes
    # candidates greedily, so without the rank a coincidental cross-currency candidate
    # one day closer would claim a transaction whose real exact-amount counterpart
    # appears one day later.
    #
    # NOTE: this is passed through `.squish`, which collapses all whitespace (including
    # newlines) into single spaces -- a `--` SQL line comment anywhere in this heredoc would
    # swallow the remainder of the query. Put explanatory comments here in Ruby instead.
    def transfer_match_candidates_sql
      <<~SQL.squish
        SELECT transfer_match_candidates.*
        FROM (
          SELECT
            inflow_candidates.entryable_id AS inflow_transaction_id,
            outflow_candidates.entryable_id AS outflow_transaction_id,
            ABS(inflow_candidates.date - outflow_candidates.date) AS date_diff,
            0 AS match_rank,
            rejected_transfers.id AS rejected_transfer_id
          FROM entries inflow_candidates
          JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id
          JOIN entries outflow_candidates ON (
            outflow_candidates.entryable_type = 'Transaction' AND
            outflow_candidates.excluded = FALSE AND
            outflow_candidates.amount > 0 AND
            outflow_candidates.account_id <> inflow_candidates.account_id AND
            outflow_candidates.date BETWEEN inflow_candidates.date - :date_window AND inflow_candidates.date + :date_window AND
            outflow_candidates.currency = inflow_candidates.currency AND
            outflow_candidates.amount = -inflow_candidates.amount
          )
          JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id
          LEFT JOIN transfers existing_transfers ON (
            existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
            existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          LEFT JOIN rejected_transfers ON (
            rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
            rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          WHERE
            inflow_candidates.entryable_type = 'Transaction' AND
            inflow_candidates.excluded = FALSE AND
            inflow_candidates.amount < 0 AND
            inflow_accounts.family_id = :family_id AND
            outflow_accounts.family_id = :family_id AND
            inflow_accounts.status IN ('draft', 'active') AND
            outflow_accounts.status IN ('draft', 'active') AND
            existing_transfers.id IS NULL AND
            (:account_id IS NULL OR inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id) AND
            (:inflow_transaction_id IS NULL OR inflow_candidates.entryable_id = :inflow_transaction_id) AND
            (:outflow_transaction_id IS NULL OR outflow_candidates.entryable_id = :outflow_transaction_id) AND
            (:filter_transaction_ids = FALSE OR inflow_candidates.entryable_id IN (:transaction_ids) OR outflow_candidates.entryable_id IN (:transaction_ids)) AND
            (:include_rejected = TRUE OR rejected_transfers.id IS NULL) AND
            #{same_wise_item_condition_sql} AND
            #{common_writer_condition_sql}
          UNION ALL
          SELECT
            inflow_candidates.entryable_id AS inflow_transaction_id,
            outflow_candidates.entryable_id AS outflow_transaction_id,
            ABS(inflow_candidates.date - outflow_candidates.date) AS date_diff,
            1 AS match_rank,
            rejected_transfers.id AS rejected_transfer_id
          FROM entries inflow_candidates
          JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id
          JOIN entries outflow_candidates ON (
            outflow_candidates.entryable_type = 'Transaction' AND
            outflow_candidates.excluded = FALSE AND
            outflow_candidates.amount > 0 AND
            outflow_candidates.account_id <> inflow_candidates.account_id AND
            outflow_candidates.date BETWEEN inflow_candidates.date - :date_window AND inflow_candidates.date + :date_window AND
            outflow_candidates.currency <> inflow_candidates.currency
          )
          JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id
          LEFT JOIN exchange_rates direct_rates ON (
            direct_rates.date = outflow_candidates.date AND
            direct_rates.from_currency = outflow_candidates.currency AND
            direct_rates.to_currency = inflow_candidates.currency
          )
          LEFT JOIN exchange_rates outflow_family_rates ON (
            outflow_family_rates.date = outflow_candidates.date AND
            outflow_family_rates.from_currency = outflow_candidates.currency AND
            outflow_family_rates.to_currency = :family_currency
          )
          LEFT JOIN exchange_rates inflow_family_rates ON (
            inflow_family_rates.date = outflow_candidates.date AND
            inflow_family_rates.from_currency = inflow_candidates.currency AND
            inflow_family_rates.to_currency = :family_currency
          )
          LEFT JOIN (
            SELECT DISTINCT
              route_outflows.account_id AS outflow_account_id,
              route_inflows.account_id AS inflow_account_id
            FROM transfers confirmed_transfers
            JOIN entries route_outflows ON (
              route_outflows.entryable_type = 'Transaction' AND
              route_outflows.entryable_id = confirmed_transfers.outflow_transaction_id
            )
            JOIN entries route_inflows ON (
              route_inflows.entryable_type = 'Transaction' AND
              route_inflows.entryable_id = confirmed_transfers.inflow_transaction_id
            )
            JOIN accounts route_accounts ON route_accounts.id = route_outflows.account_id
            WHERE
              :restrict_cross_currency_to_linked_accounts = TRUE AND
              confirmed_transfers.status = 'confirmed' AND
              route_accounts.family_id = :family_id
          ) confirmed_routes ON (
            confirmed_routes.outflow_account_id = outflow_candidates.account_id AND
            confirmed_routes.inflow_account_id = inflow_candidates.account_id
          )
          LEFT JOIN transfers existing_transfers ON (
            existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
            existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          LEFT JOIN rejected_transfers ON (
            rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
            rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          WHERE
            inflow_candidates.entryable_type = 'Transaction' AND
            inflow_candidates.excluded = FALSE AND
            inflow_candidates.amount < 0 AND
            inflow_accounts.family_id = :family_id AND
            outflow_accounts.family_id = :family_id AND
            inflow_accounts.status IN ('draft', 'active') AND
            outflow_accounts.status IN ('draft', 'active') AND
            existing_transfers.id IS NULL AND
            (:account_id IS NULL OR inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id) AND
            ABS(inflow_candidates.amount / NULLIF(outflow_candidates.amount * COALESCE(
              NULLIF(direct_rates.rate, 0),
              (CASE WHEN outflow_candidates.currency = :family_currency THEN 1 ELSE outflow_family_rates.rate END) /
                NULLIF(CASE WHEN inflow_candidates.currency = :family_currency THEN 1 ELSE inflow_family_rates.rate END, 0)
            ), 0))
              BETWEEN :lower_exchange_rate_bound AND :upper_exchange_rate_bound AND
            (:inflow_transaction_id IS NULL OR inflow_candidates.entryable_id = :inflow_transaction_id) AND
            (:outflow_transaction_id IS NULL OR outflow_candidates.entryable_id = :outflow_transaction_id) AND
            (:filter_transaction_ids = FALSE OR inflow_candidates.entryable_id IN (:transaction_ids) OR outflow_candidates.entryable_id IN (:transaction_ids)) AND
            (:include_rejected = TRUE OR rejected_transfers.id IS NULL) AND
            (
              :restrict_cross_currency_to_linked_accounts = FALSE OR
              (#{linked_account_sql("inflow_accounts")} AND #{linked_account_sql("outflow_accounts")}) OR
              confirmed_routes.outflow_account_id IS NOT NULL
            ) AND
            #{same_wise_item_condition_sql} AND
            #{common_writer_condition_sql}
        ) transfer_match_candidates
        ORDER BY transfer_match_candidates.match_rank ASC, transfer_match_candidates.date_diff ASC
      SQL
    end

    # The inverse of Account#manual? / the Account.manual scope, inlined as SQL so
    # it can run against the inflow/outflow account aliases in the same query
    # rather than round-tripping through AR. Keep in sync with Account#manual? if
    # what counts as "linked" ever changes (e.g. a new provider type).
    def linked_account_sql(accounts_alias)
      <<~SQL.squish
        (
          #{accounts_alias}.plaid_account_id IS NOT NULL OR
          #{accounts_alias}.simplefin_account_id IS NOT NULL OR
          EXISTS (SELECT 1 FROM account_providers WHERE account_providers.account_id = #{accounts_alias}.id)
        )
      SQL
    end
end
