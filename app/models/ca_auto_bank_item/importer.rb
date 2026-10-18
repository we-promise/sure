class CaAutoBankItem::Importer
  def initialize(item)
    @item = item
  end

  def import(snapshot:, parent_sync: nil, window_start_date: nil, window_end_date: nil)
    normalized = CaAutoBankItem::SnapshotNormalizer.new.normalize(snapshot)
    imported_accounts = []
    ApplicationRecord.transaction do
      owner = @item.owner
      raise Provider::CaAutoBank::Error.new(:account_identity_changed) unless owner

      owner.with_lock do
        @item.with_lock do
          unless @item.ready_for_sync? && @item.connection_generation == normalized.generation && @item.account_identity == normalized.identity
            raise Provider::CaAutoBank::Error.new(:account_identity_changed)
          end
          if @item.snapshot_at && @item.snapshot_at > normalized.observed_at
            raise Provider::CaAutoBank::Error.new(:stale_snapshot)
          end

          existing = @item.ca_auto_bank_accounts.includes(account_provider: :account).to_a
          if (existing.map(&:report_uid).uniq - normalized.report_uids).any?
            raise Provider::CaAutoBank::Error.new(:incomplete_snapshot)
          end
          normalized.accounts.each do |data|
            provider_account = existing.find { |record| record.uid == data.uid } || @item.ca_auto_bank_accounts.build(uid: data.uid)
            bootstrap = provider_account.new_record?
            if !bootstrap && (provider_account.report_uid != data.report_uid || provider_account.kind != data.kind)
              raise Provider::CaAutoBank::Error.new(:account_conflict)
            end
            provider_account.assign_attributes(report_uid: data.report_uid, kind: data.kind, name: data.name,
              current_balance: data.balance, interest_rate: data.rate, effective_date: data.effective_date,
              maturity_date: data.maturity_date, deposit_metadata: data.metadata)
            provider_account.save!
            provider_account.ensure_link!(bootstrap: bootstrap)
            account = apply_balance!(provider_account, data.balance, normalized.date)
            imported_accounts << account
          end

          active_uids = normalized.accounts.map(&:uid)
          existing.reject { |record| active_uids.include?(record.uid) }.each do |missing|
            raise Provider::CaAutoBank::Error.new(:incomplete_snapshot) unless missing.kind == "time_deposit"

            missing.update!(current_balance: 0, deposit_metadata: (missing.deposit_metadata || {}).merge("status" => "NOT_ACTIVE"))
            account = apply_balance!(missing, 0, normalized.date)
            imported_accounts << account
          end
          @item.update!(snapshot_at: normalized.observed_at, last_sync_error_code: nil)
        end
      end
    end

    imported_accounts.uniq.each do |account|
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
    end
    imported_accounts
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    raise Provider::CaAutoBank::Error.new(:account_conflict), cause: nil
  end

  private

    def apply_balance!(provider_account, amount, date)
      link = provider_account.reload.account_provider
      locked_account = Account.lock.find_by(id: link&.account_id)
      provider_account.reload
      account = provider_account.usable_account
      raise Provider::CaAutoBank::Error.new(:account_conflict) unless locked_account && account&.id == locked_account.id
      raise Provider::CaAutoBank::Error.new(:account_conflict) unless account
      raise Provider::CaAutoBank::Error.new(:stale_snapshot) if account.current_anchor_date && account.current_anchor_date > date

      result = account.set_current_balance(amount, date: date, schedule_sync: false)
      unless result.success? && !result.historical?
        raise Provider::CaAutoBank::Error.new(:stale_snapshot)
      end
      account.update!(cash_balance: amount)
      account
    end
end
