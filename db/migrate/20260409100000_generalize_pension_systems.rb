class GeneralizePensionSystems < ActiveRecord::Migration[7.2]
  def change
    # Add JSONB column for system-specific parameters (replaces rentenwert, expected_annual_points)
    add_column :retirement_configs, :pension_params, :jsonb, null: false, default: {}

    # Add JSONB column for system-specific entry data
    add_column :pension_entries, :data, :jsonb, null: false, default: {}

    # Make current_points nullable (only used by points-based systems like DE)
    change_column_null :pension_entries, :current_points, true

    # Migrate existing data: move rentenwert and expected_annual_points into pension_params
    reversible do |dir|
      dir.up do
        execute <<-SQL.squish
          UPDATE retirement_configs
          SET pension_params = jsonb_build_object(
            'rentenwert', COALESCE(rentenwert, 39.32),
            'expected_annual_points', COALESCE(expected_annual_points, 1.0),
            'contribution_start_year', contribution_start_year
          )
          WHERE pension_system = 'de_grv'
        SQL
      end
    end

    # Remove old German-specific columns
    remove_column :retirement_configs, :rentenwert, :decimal, precision: 8, scale: 2
    remove_column :retirement_configs, :expected_annual_points, :decimal, precision: 5, scale: 2
    remove_column :retirement_configs, :contribution_start_year, :integer
  end
end
