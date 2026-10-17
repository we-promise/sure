class FinecoItem::Importer
  def initialize(item)
    @item = item
  end

  def import(payload:, captured_at:, parent_sync: nil, window_start_date: nil, window_end_date: nil, allow_account_bootstrap: false)
    raise FinecoItem::PortfolioImportError.new(:identity_verification_required) unless Provider::Fineco.verified_identity_contract?

    snapshot = FinecoItem::PortfolioNormalizer.new(payload: payload, captured_at: captured_at).normalize
    account = nil

    ApplicationRecord.transaction(requires_new: true) do
      @item.save! if @item.new_record? || @item.changed?

      provider_account = ensure_fineco_account!(allow_account_bootstrap: allow_account_bootstrap)
      account_provider = provider_account.account_provider
      account = validate_linked_account!(provider_account, account_provider)
      reject_stale_snapshot!(provider_account, account, snapshot)

      account.update!(cash_balance: 0)
      FinecoAccount::HoldingsProcessor.new(provider_account).process(snapshot)

      balance_result = account.set_current_balance(
        snapshot.market_value,
        date: snapshot.date,
        schedule_sync: false
      )
      unless balance_result.success? && !balance_result.historical?
        raise FinecoItem::PortfolioImportError.new(:stale_snapshot)
      end

      account.update!(balance: snapshot.market_value, cash_balance: 0)
      @item.update!(
        status: :good,
        portfolio_snapshot_at: snapshot.captured_at,
        last_sync_error_code: nil
      )
    end

    account.sync_later(
      parent_sync: parent_sync,
      window_start_date: window_start_date,
      window_end_date: window_end_date
    )
    account
  rescue FinecoItem::PortfolioImportError
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise FinecoItem::PortfolioImportError.new(:sync_failed), cause: nil
  rescue StandardError
    raise FinecoItem::PortfolioImportError.new(:sync_failed), cause: nil
  end

  private

    def ensure_fineco_account!(allow_account_bootstrap:)
      account = @item.fineco_accounts.find_or_initialize_by(external_id: FinecoAccount::EXTERNAL_ID)
      account.assign_attributes(name: "Fineco investments", currency: "EUR")
      account.save!
      account.ensure_account_provider!(allow_bootstrap: allow_account_bootstrap)
      account
    end

    def validate_linked_account!(provider_account, account_provider)
      account = account_provider&.account
      valid = account.present? &&
        account_provider.provider_type == "FinecoAccount" &&
        account_provider.provider_id == provider_account.id &&
        account.family_id == @item.family_id &&
        account.owner_id == @item.owner_id &&
        account.accountable_type == "Investment" &&
        account.currency == "EUR" &&
        account.status == "active" &&
        !account.disabled? &&
        !account.pending_deletion? &&
        account.account_providers.where.not(id: account_provider.id).none?

      raise FinecoItem::PortfolioImportError.new(:account_conflict) unless valid

      account
    end

    def reject_stale_snapshot!(provider_account, account, snapshot)
      last_snapshot_date = provider_account.last_snapshot_date
      last_snapshot_at = @item.portfolio_snapshot_at
      anchor_date = account.current_anchor_date
      raise FinecoItem::PortfolioImportError.new(:stale_snapshot) if last_snapshot_at && last_snapshot_at > snapshot.captured_at
      return unless [ last_snapshot_date, anchor_date ].compact.any? { |date| date > snapshot.date }

      raise FinecoItem::PortfolioImportError.new(:stale_snapshot)
    end
end
