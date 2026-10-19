class ScalableItem::Importer
  SNAPSHOT_NAME = "Scalable Broker".freeze

  def initialize(item)
    @item = item
  end

  def import(snapshot:, parent_sync: nil, window_start_date: nil, window_end_date: nil)
    validate_snapshot!(snapshot)
    imported_accounts = []

    ApplicationRecord.transaction(requires_new: true) do
      owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
      raise Provider::Scalable::Error.new(:account_conflict) unless owner&.active?

      owner.with_lock do
        @item.with_lock do
          validate_current_identity!(snapshot)
          reject_missing_portfolios!(snapshot)

          snapshot.accounts.each do |portfolio|
            provider_account = @item.scalable_accounts.find_or_initialize_by(uid: portfolio.uid)
            allow_bootstrap = provider_account.new_record?
            if provider_account.persisted? && provider_account.kind != ScalableAccount::BROKER_KIND
              raise Provider::Scalable::Error.new(:account_conflict)
            end
            validate_account_binding!(provider_account, snapshot.account_id)
            reject_stale_snapshot!(provider_account, provider_account.current_account, portfolio)

            provider_account.assign_attributes(
              name: portfolio.name,
              currency: portfolio.currency,
              kind: ScalableAccount::BROKER_KIND,
              current_balance: portfolio.current_balance,
              cash_balance: portfolio.cash_balance,
              raw_metadata: JSON.generate(portfolio.raw_metadata),
              snapshot_at: portfolio.observed_at
            )
            provider_account.save!
            provider_account.ensure_account_provider!(allow_bootstrap: allow_bootstrap)

            account = provider_account.usable_account
            raise Provider::Scalable::Error.new(:account_conflict) unless account
            reject_stale_snapshot!(provider_account, account, portfolio)

            provider_account.clear_generated_snapshot_rows!(account)
            ScalableAccount::HoldingsProcessor.new(provider_account).process(portfolio)
            result = account.set_current_balance(
              portfolio.current_balance,
              date: portfolio.observed_at.utc.to_date,
              schedule_sync: false
            )
            unless result.success? && !result.historical?
              raise Provider::Scalable::Error.new(:stale_snapshot)
            end

            account.update!(cash_balance: portfolio.cash_balance)
            imported_accounts << account
          end

          @item.update!(
            snapshot_at: snapshot.fetched_at,
            last_sync_error_code: nil,
            next_sync_at: 5.minutes.from_now
          )
        end
      end
    end

    ActiveRecord.after_all_transactions_commit do
      imported_accounts.uniq.each do |account|
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
      end
    end

    imported_accounts.uniq
  rescue Provider::Scalable::Error
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise Provider::Scalable::Error.new(:account_conflict), cause: nil
  end

  private

    def validate_snapshot!(snapshot)
      valid = snapshot.is_a?(ScalableItem::PortfolioNormalizer::Snapshot) &&
        snapshot.account_id.is_a?(String) && snapshot.account_id.present? &&
        snapshot.person_identity.to_s == @item.person_identity.to_s &&
        snapshot.connection_generation == @item.connection_generation &&
        snapshot.fetched_at.is_a?(Time) &&
        snapshot.accounts.is_a?(Array) && snapshot.accounts.any? &&
        snapshot.accounts.all? do |portfolio|
          portfolio.is_a?(ScalableItem::PortfolioNormalizer::BrokerPortfolio) &&
            portfolio.observed_at.is_a?(Time) && portfolio.valuation_timestamp.is_a?(Time)
        end
      raise Provider::Scalable::Error.new(:invalid_snapshot) unless valid

      ids = snapshot.accounts.map(&:uid)
      raise Provider::Scalable::Error.new(:invalid_snapshot) unless ids.uniq.length == ids.length
    end

    def validate_current_identity!(snapshot)
      valid = @item.connected? && @item.ready_for_sync? &&
        @item.person_identity.to_s == snapshot.person_identity.to_s &&
        @item.connection_generation == snapshot.connection_generation
      raise Provider::Scalable::Error.new(:account_identity_changed) unless valid
    end

    def validate_account_binding!(provider_account, account_id)
      return unless provider_account.persisted?

      metadata = JSON.parse(provider_account.raw_metadata.to_s)
      stored_account_id = metadata["account_id"] if metadata.is_a?(Hash)
      raise Provider::Scalable::Error.new(:account_conflict) unless stored_account_id == account_id
    rescue JSON::ParserError
      raise Provider::Scalable::Error.new(:account_conflict), cause: nil
    end

    def reject_missing_portfolios!(snapshot)
      incoming_ids = snapshot.accounts.map(&:uid)
      existing_ids = @item.scalable_accounts.where(kind: ScalableAccount::BROKER_KIND).pluck(:uid)
      return if (existing_ids - incoming_ids).empty?

      raise Provider::Scalable::Error.new(:invalid_snapshot)
    end

    def reject_stale_snapshot!(provider_account, account, portfolio)
      last_snapshot_at = provider_account.snapshot_at
      last_valuation_timestamp = stored_valuation_timestamp(provider_account)
      snapshot_date = portfolio.observed_at.utc.to_date
      latest_holding_date = if account
        account.holdings.where.not(account_provider_id: nil).maximum(:date)
      end

      if last_snapshot_at && last_snapshot_at > portfolio.observed_at
        raise Provider::Scalable::Error.new(:stale_snapshot)
      end
      if last_valuation_timestamp && last_valuation_timestamp > portfolio.valuation_timestamp
        raise Provider::Scalable::Error.new(:stale_snapshot)
      end
      if [ account&.current_anchor_date, latest_holding_date ].compact.any? { |date| date > snapshot_date }
        raise Provider::Scalable::Error.new(:stale_snapshot)
      end
    end

    def stored_valuation_timestamp(provider_account)
      return unless provider_account.persisted? && provider_account.raw_metadata.present?

      metadata = JSON.parse(provider_account.raw_metadata)
      return unless metadata.is_a?(Hash)
      return if metadata["valuation_timestamp"].blank?
      return unless metadata["valuation_timestamp"].is_a?(String)

      Time.iso8601(metadata.fetch("valuation_timestamp"))
    rescue JSON::ParserError, ArgumentError, TypeError
      raise Provider::Scalable::Error.new(:account_conflict), cause: nil
    end
end
