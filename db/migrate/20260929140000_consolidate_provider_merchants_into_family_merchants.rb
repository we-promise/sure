class ConsolidateProviderMerchantsIntoFamilyMerchants < ActiveRecord::Migration[8.1]
  def up
    # Family merchants become unique by family, name, and website. This lets a
    # family keep two same-named merchants when they are genuinely different.
    remove_index :merchants, name: "index_merchants_on_family_id_and_name"
    add_index :merchants,
              "family_id, name, COALESCE(website_url, '')",
              unique: true,
              name: "index_family_merchants_on_name_and_website"

    provider_merchants = Merchant.where(type: "ProviderMerchant").pluck(:id, :name, :website_url, :logo_url)

    provider_merchants.each do |provider_id, name, website_url, logo_url|
      family_ids = transaction_family_ids(provider_id) + recurring_family_ids(provider_id) + association_family_ids(provider_id)

      family_ids.uniq.each do |family_id|
        family_merchant = FamilyMerchant.find_by(
          family_id: family_id,
          name: name,
          website_url: website_url
        )
        family_merchant ||= FamilyMerchant.create!(
          family_id: family_id,
          name: name,
          website_url: website_url,
          logo_url: logo_url
        )

        transaction_ids = Transaction.joins(entry: :account)
                                     .where(accounts: { family_id: family_id }, merchant_id: provider_id)
                                     .select(:id)
        Transaction.where(id: transaction_ids).update_all(merchant_id: family_merchant.id)
        RecurringTransaction.where(family_id: family_id, merchant_id: provider_id)
                            .update_all(merchant_id: family_merchant.id)
      end
    end

    association_model = Class.new(ActiveRecord::Base) { self.table_name = "family_merchant_associations" }
    association_model.delete_all
    drop_table :family_merchant_associations
    Merchant.where(type: "ProviderMerchant").delete_all

    remove_index :merchants, name: "index_merchants_on_provider_merchant_id_and_source"
    remove_index :merchants, name: "index_merchants_on_source_and_name"
    remove_column :merchants, :provider_merchant_id
    remove_column :merchants, :source
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Provider merchant rows and family associations were consolidated"
  end

  private

  def transaction_family_ids(merchant_id)
    Transaction.joins(entry: :account)
               .where(merchant_id: merchant_id)
               .distinct
               .pluck("accounts.family_id")
  end

  def recurring_family_ids(merchant_id)
    RecurringTransaction.where(merchant_id: merchant_id).distinct.pluck(:family_id)
  end

  def association_family_ids(merchant_id)
    association_model = Class.new(ActiveRecord::Base) { self.table_name = "family_merchant_associations" }
    association_model.where(merchant_id: merchant_id).distinct.pluck(:family_id)
  end
end
