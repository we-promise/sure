class AddFirstProviderPriceSourceToSecurities < ActiveRecord::Migration[8.1]
  # first_provider_price_on is the first date a provider could price the
  # security. Recording which provider found it lets a later sync ignore a
  # date another provider set. Unassigned securities may hold a date the keyless
  # Yahoo substitute found, so theirs is cleared; the next sync rediscovers it.
  def up
    add_column :securities, :first_provider_price_source, :string

    execute <<~SQL
      UPDATE securities
      SET first_provider_price_on = NULL
      WHERE price_provider IS NULL AND first_provider_price_on IS NOT NULL
    SQL
  end

  def down
    remove_column :securities, :first_provider_price_source
  end
end
