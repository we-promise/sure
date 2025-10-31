# frozen_string_literal: true

class SimplefinItem::Unlinker
  attr_reader :item, :dry_run

  def initialize(item, dry_run: false)
    @item = item
    @dry_run = dry_run
  end

  def unlink_all!
    results = []

    ActiveRecord::Base.transaction do
      item.simplefin_accounts.includes(:account).each do |sfa|
        ap = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
        results << { sfa_id: sfa.id, name: sfa.name, account_id: sfa.account_id, provider_link_id: ap&.id }

        next if dry_run

        if ap
          # Detach dependent holdings that reference this provider link, then remove the link
          Holding.where(account_provider_id: ap.id).update_all(account_provider_id: nil)
          ap.destroy!
        end
        # Legacy FK fallback
        sfa.update!(account: nil) if sfa.account_id.present?
      end
    end

    results
  end
end
