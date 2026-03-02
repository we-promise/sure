# frozen_string_literal: true

class AddOpenaiUriBaseToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :openai_uri_base, :string
  end
end
