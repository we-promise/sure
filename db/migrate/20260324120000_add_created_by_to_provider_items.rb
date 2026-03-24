class AddCreatedByToProviderItems < ActiveRecord::Migration[7.2]
  PROVIDER_TABLES = %i[
    plaid_items simplefin_items lunchflow_items enable_banking_items
    coinstats_items mercury_items coinbase_items snaptrade_items indexa_capital_items
  ].freeze

  def change
    PROVIDER_TABLES.each do |table|
      add_reference table, :created_by, type: :uuid, foreign_key: { to_table: :users }, null: true, index: true
    end

    reversible do |dir|
      dir.up do
        Family.find_each do |family|
          admin = family.users.find_by(role: %w[admin super_admin]) || family.users.order(:created_at).first
          next unless admin

          PROVIDER_TABLES.each do |table|
            ActiveRecord::Base.connection.execute(
              ActiveRecord::Base.sanitize_sql_array([
                "UPDATE #{table} SET created_by_id = ? WHERE family_id = ? AND created_by_id IS NULL",
                admin.id, family.id
              ])
            )
          end
        end
      end
    end
  end
end
