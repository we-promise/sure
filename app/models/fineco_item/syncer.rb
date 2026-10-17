class FinecoItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    failure = nil

    @item.with_lock do
      begin
        unless Provider::Fineco.verified_identity_contract?
          raise FinecoItem::PortfolioImportError.new(:identity_verification_required)
        end
        unless ActiveRecordEncryptionConfig.explicitly_configured?
          raise FinecoItem::PortfolioImportError.new(:encryption_unavailable)
        end
        unless @item.good? && @item.session_configured?
          raise FinecoItem::PortfolioImportError.new(:reauthentication_required)
        end
        unless active_owner?
          raise FinecoItem::PortfolioImportError.new(:reauthentication_required)
        end
        unless @item.account_link_ready?
          raise FinecoItem::PortfolioImportError.new(:account_conflict)
        end

        result = Provider::Fineco.new(
          gsessionid: @item.gsessionid,
          account_index: @item.account_index,
          dossier_index: @item.dossier_index
        ).fetch_portfolio_summary

        unless @item.same_bank_identity?(account_number: result.account_number, dossier_identity: result.dossier_identity)
          @item.require_reauthentication!(code: "account_identity_changed")
          raise FinecoItem::PortfolioImportError.new(:account_identity_changed)
        end

        owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
        raise FinecoItem::PortfolioImportError.new(:reauthentication_required) unless owner

        owner.with_lock do
          raise FinecoItem::PortfolioImportError.new(:reauthentication_required) unless owner.active?
          raise FinecoItem::PortfolioImportError.new(:account_conflict) unless @item.account_link_ready?

          @item.update!(
            gsessionid: result.rotated_gsessionid.presence || @item.gsessionid,
            captured_at: Time.current,
            status: :good
          )
          @item.import_portfolio_snapshot!(
            payload: result.payload,
            captured_at: @item.captured_at,
            parent_sync: sync,
            window_start_date: sync.window_start_date,
            window_end_date: sync.window_end_date
          )
        end
      rescue Provider::Fineco::ReauthenticationRequired
        @item.require_reauthentication!
        failure = FinecoItem::PortfolioImportError.new(:reauthentication_required)
      rescue FinecoItem::PortfolioImportError => error
        @item.require_reauthentication! if error.code == "reauthentication_required" && !@item.requires_update?
        @item.record_sync_failure!(error.code)
        failure = error
      rescue Provider::Fineco::Error
        @item.record_sync_failure!(:sync_failed)
        failure = FinecoItem::PortfolioImportError.new(:sync_failed)
      rescue StandardError
        @item.record_sync_failure!(:sync_failed)
        failure = FinecoItem::PortfolioImportError.new(:sync_failed)
      end
    end

    raise failure if failure
  end

  def perform_post_sync
  end

  private

    def active_owner?
      User.where(id: @item.owner_id, family_id: @item.family_id, active: true).exists?
    end
end
