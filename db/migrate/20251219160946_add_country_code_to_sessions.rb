class AddCountryCodeToSessions < ActiveRecord::Migration[7.1]
  def change
    add_column :sessions, :country_code, :string
  end
end
