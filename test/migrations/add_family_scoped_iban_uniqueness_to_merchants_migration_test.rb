# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260911184745_add_family_scoped_iban_uniqueness_to_merchants")

class AddFamilyScopedIbanUniquenessToMerchantsMigrationTest < ActiveSupport::TestCase
  test "refuses to run when duplicate family-scoped ibans already exist" do
    # The schema already has this migration's index applied (it's part of
    # db/schema.rb); drop it first to simulate the pre-migration state the
    # duplicate check needs to guard, since the DB-level constraint would
    # otherwise block the duplicate insert below before the migration is
    # even involved.
    ActiveRecord::Base.connection.execute("DROP INDEX IF EXISTS index_merchants_on_family_id_and_iban")

    family = families(:dylan_family)
    FamilyMerchant.create!(name: "Landlord A", family: family, iban: "AT611904300234573201") # pipelock:ignore IBAN
    # Bypasses the model uniqueness this migration is meant to add at the DB
    # level too -- simulates data that predates either.
    FamilyMerchant.create!(name: "Landlord B", family: family).update_column(:iban, "AT611904300234573201") # pipelock:ignore IBAN

    error = assert_raises(RuntimeError) { AddFamilyScopedIbanUniquenessToMerchants.new.up }

    assert_match "already share an iban within the same family", error.message
    # Standard transactional test rollback undoes both the DROP INDEX above
    # and the duplicate rows once this test finishes, restoring the schema
    # for subsequent tests without any manual cleanup here.
  end
end
