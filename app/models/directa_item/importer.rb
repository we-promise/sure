class DirectaItem::Importer
  Result = Data.define(:account, :snapshot)

  def initialize(item)
    @item = item
  end

  def import(snapshot:, parent_sync: nil, window_start_date: nil, window_end_date: nil)
    unless ActiveRecordEncryptionConfig.explicitly_configured?
      raise DirectaItem::PortfolioNormalizer::Error.new(:sync_failed)
    end

    normalized = DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)
    account = nil

    ApplicationRecord.transaction(requires_new: true) do
      @item.with_lock do
        validate_current_session!(normalized)
        reject_stale_snapshot!(normalized)

        provider_account = @item.directa_accounts.find_or_initialize_by(directa_item_id: @item.id)
        provider_account.assign_attributes(
          currency: normalized.currency,
          current_balance: normalized.current_balance,
          cash_balance: normalized.cash_balance,
          raw_position_metadata: normalized.raw_position_metadata
        )
        provider_account.save!

        provider_account.ensure_account_provider!(allow_bootstrap: true)
        account = provider_account.usable_account
        raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict) unless account
        DirectaAccount::ContentValidator.new(provider_account).validate!
        reject_stale_snapshot!(normalized, account: account)

        DirectaAccount::HoldingsProcessor.new(provider_account).process(normalized)

        balance_result = account.set_current_balance(
          normalized.current_balance,
          date: normalized.date,
          schedule_sync: false
        )
        unless balance_result.success? && !balance_result.historical?
          raise DirectaItem::PortfolioNormalizer::Error.new(:stale_snapshot)
        end

        account.update!(cash_balance: normalized.cash_balance)
        @item.update!(portfolio_snapshot_at: normalized.observed_at, last_sync_error_code: nil)
      end
    end

    account.sync_later(
      parent_sync: parent_sync,
      window_start_date: window_start_date,
      window_end_date: window_end_date
    )

    Result.new(account: account, snapshot: normalized)
  rescue DirectaItem::PortfolioNormalizer::Error => error
    record_sync_failure(error.code, expected_generation: snapshot.connection_generation)
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    record_sync_failure("sync_failed", expected_generation: snapshot.connection_generation)
    raise DirectaItem::PortfolioNormalizer::Error.new(:sync_failed), cause: nil
  rescue StandardError
    record_sync_failure("sync_failed", expected_generation: snapshot.connection_generation)
    raise DirectaItem::PortfolioNormalizer::Error.new(:sync_failed), cause: nil
  end

  private

    def validate_current_session!(snapshot)
      session_matches = @item.connected? && @item.ready_for_sync? &&
        @item.connection_generation == snapshot.connection_generation &&
        secure_equal?(@item.account_identity, snapshot.account_identity) &&
        secure_equal?(@item.broker_account, snapshot.account_number)
      return if session_matches

      raise DirectaItem::PortfolioNormalizer::Error.new(:account_identity_changed)
    end

    def reject_stale_snapshot!(snapshot, account: nil)
      previous = @item.portfolio_snapshot_at
      anchor_date = account&.current_anchor_date
      holdings_date = account&.latest_provider_holdings_snapshot_date
      return unless (previous && previous > snapshot.observed_at) ||
        [ anchor_date, holdings_date ].compact.any? { |date| date > snapshot.date }

      raise DirectaItem::PortfolioNormalizer::Error.new(:stale_snapshot)
    end

    def secure_equal?(left, right)
      return false if left.blank? || right.blank?
      return false unless left.to_s.bytesize == right.to_s.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end

    def record_sync_failure(code, expected_generation:)
      return unless @item.persisted? && expected_generation

      @item.with_lock do
        @item.record_sync_failure!(code) if @item.connection_generation == expected_generation
      end
    end
end
