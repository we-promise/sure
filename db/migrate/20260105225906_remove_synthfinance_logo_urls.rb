class RemoveSynthfinanceLogoUrls < ActiveRecord::Migration[7.2]
  def up
    # Remove logo URLs pointing to the old synthfinance.com domain
    # These URLs are no longer valid and should be set to NULL
    execute <<-SQL
      UPDATE merchants
      SET logo_url = NULL
      WHERE logo_url LIKE '%logo.synthfinance.com%'
    SQL
  end

  def down
    # No-op: we can't restore the old logo URLs
  end
end
