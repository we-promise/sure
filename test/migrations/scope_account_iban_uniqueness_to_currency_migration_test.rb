# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261007150000_scope_account_iban_uniqueness_to_currency")

class ScopeAccountIbanUniquenessToCurrencyMigrationTest < ActiveSupport::TestCase
  OLD_INDEX_NAME = ScopeAccountIbanUniquenessToCurrency::OLD_INDEX_NAME
  NEW_INDEX_NAME = ScopeAccountIbanUniquenessToCurrency::NEW_INDEX_NAME

  test "up is a no-op once the currency-scoped index exists" do
    ScopeAccountIbanUniquenessToCurrency.new.up

    connection = ActiveRecord::Base.connection
    assert connection.index_name_exists?(:accounts, NEW_INDEX_NAME)
    assert_not connection.index_name_exists?(:accounts, OLD_INDEX_NAME)
  end

  test "down refuses to restore the stricter index while an iban is shared across currencies" do
    family = families(:dylan_family)
    eur = family.accounts.create!(name: "Multi-currency EUR", balance: 0, currency: "EUR", accountable: Depository.new, iban: "DE89370400440532013000") # pipelock:ignore IBAN
    usd = family.accounts.create!(name: "Multi-currency USD", balance: 0, currency: "USD", accountable: Depository.new, iban: "DE89370400440532013000") # pipelock:ignore IBAN

    error = assert_raises(RuntimeError) { ScopeAccountIbanUniquenessToCurrency.new.down }

    assert_match "share an iban within the same family", error.message
    assert_includes error.message, eur.id
    assert_includes error.message, usd.id
    assert ActiveRecord::Base.connection.index_name_exists?(:accounts, NEW_INDEX_NAME)
    assert_not ActiveRecord::Base.connection.index_name_exists?(:accounts, OLD_INDEX_NAME)
  end
end
