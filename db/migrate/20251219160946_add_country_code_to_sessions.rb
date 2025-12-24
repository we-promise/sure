class AddCountryCodeToSessions < ActiveRecord::Migration[7.2]
  def change
    add_column :sessions, :country_code, :string
  end
end
