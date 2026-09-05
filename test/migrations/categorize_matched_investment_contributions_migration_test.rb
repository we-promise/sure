# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260729000000_categorize_matched_investment_contributions")

class CategorizeMatchedInvestmentContributionsMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "categorizes confirmed matches without creating or merging categories" do
    family = families(:empty)
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    category = family.categories.create!(name: Category.investment_contributions_name, color: "#0d9488", lucide_icon: "trending-up", default_key: Category::INVESTMENT_CONTRIBUTIONS_DEFAULT_KEY)
    confirmed_outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    confirmed_inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: confirmed_outflow.entryable, inflow_transaction: confirmed_inflow.entryable, status: "confirmed")
    pending_outflow = create_transaction(account: source, amount: 200, kind: "investment_contribution")
    pending_inflow = create_transaction(account: destination, amount: -200, kind: "funds_movement")
    Transfer.create!(outflow_transaction: pending_outflow.entryable, inflow_transaction: pending_inflow.entryable, status: "pending")
    category_count = family.categories.count
    updated_at = confirmed_outflow.reload.updated_at

    travel 1.second do
      CategorizeMatchedInvestmentContributions.new.up
    end

    assert_equal category.id, confirmed_outflow.reload.entryable.category_id
    assert_nil pending_outflow.reload.entryable.category_id
    assert_equal category_count, family.categories.count
    assert_operator confirmed_outflow.reload.updated_at, :>, updated_at
  end

  test "does not create a category when a confirmed match has no existing category" do
    family = Family.create!(name: "Migration without category")
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")

    assert_no_difference -> { family.categories.count } do
      CategorizeMatchedInvestmentContributions.new.up
    end

    assert_nil outflow.reload.entryable.category_id
  end

  test "uses the durable key for a Ukrainian category" do
    family = Family.create!(name: "Migration Ukrainian family")
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    category = family.categories.create!(name: "Інвестиційні внески", color: "#0d9488", lucide_icon: "trending-up", default_key: Category::INVESTMENT_CONTRIBUTIONS_DEFAULT_KEY)
    outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")

    CategorizeMatchedInvestmentContributions.new.up

    assert_equal category.id, outflow.reload.entryable.category_id
  end

  test "does not infer a category from its display name" do
    family = Family.create!(name: "Migration display name family")
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    family.categories.create!(name: "Інвестиційні внески", color: "#0d9488", lucide_icon: "trending-up")
    outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")

    CategorizeMatchedInvestmentContributions.new.up

    assert_nil outflow.reload.entryable.category_id
  end

  test "does not use a category from a pending contribution match" do
    family = Family.create!(name: "Migration pending category family")
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    category = family.categories.create!(name: "Renamed investment category", color: "#0d9488", lucide_icon: "trending-up")

    pending_outflow = create_transaction(account: source, amount: 50, kind: "investment_contribution", category: category)
    pending_inflow = create_transaction(account: destination, amount: -50, kind: "funds_movement")
    Transfer.create!(outflow_transaction: pending_outflow.entryable, inflow_transaction: pending_inflow.entryable, status: "pending")

    confirmed_outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    confirmed_inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: confirmed_outflow.entryable, inflow_transaction: confirmed_inflow.entryable, status: "confirmed")

    CategorizeMatchedInvestmentContributions.new.up

    assert_equal category.id, pending_outflow.reload.entryable.category_id
    assert_nil confirmed_outflow.reload.entryable.category_id
  end

  test "reuses a renamed category referenced by another contribution" do
    family = Family.create!(name: "Migration renamed category family")
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    category = family.categories.create!(name: "Long-term investing", color: "#0d9488", lucide_icon: "trending-up")
    existing_outflow = create_transaction(account: source, amount: 50, kind: "investment_contribution", category: category)
    existing_inflow = create_transaction(account: destination, amount: -50, kind: "funds_movement")
    Transfer.create!(outflow_transaction: existing_outflow.entryable, inflow_transaction: existing_inflow.entryable, status: "confirmed")
    outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")

    CategorizeMatchedInvestmentContributions.new.up

    assert_equal category.id, outflow.reload.entryable.category_id
  end

  test "does not merge existing investment contribution category variants" do
    family = Family.create!(name: "Migration with duplicate categories")
    source = family.accounts.create!(name: "Migration source", currency: "USD", balance: 0, accountable: Depository.new)
    destination = family.accounts.create!(name: "Migration destination", currency: "USD", balance: 0, accountable: Investment.new)
    category = family.categories.create!(name: Category.investment_contributions_name, color: "#0d9488", lucide_icon: "trending-up", default_key: Category::INVESTMENT_CONTRIBUTIONS_DEFAULT_KEY)
    duplicate_name = Category.all_investment_contributions_names.find { |name| name != category.name }
    assert_not_nil duplicate_name
    duplicate_category = family.categories.create!(name: duplicate_name, color: "#0d9488", lucide_icon: "trending-up")

    existing_outflow = create_transaction(account: source, amount: 50, kind: "investment_contribution", category: duplicate_category)
    existing_inflow = create_transaction(account: destination, amount: -50, kind: "funds_movement")
    Transfer.create!(outflow_transaction: existing_outflow.entryable, inflow_transaction: existing_inflow.entryable, status: "confirmed")
    backfill_outflow = create_transaction(account: source, amount: 100, kind: "investment_contribution")
    backfill_inflow = create_transaction(account: destination, amount: -100, kind: "funds_movement")
    Transfer.create!(outflow_transaction: backfill_outflow.entryable, inflow_transaction: backfill_inflow.entryable, status: "confirmed")

    assert_no_difference -> { family.categories.count } do
      CategorizeMatchedInvestmentContributions.new.up
    end

    assert Category.exists?(duplicate_category.id)
    assert_equal duplicate_category.id, existing_outflow.reload.entryable.category_id
    assert_equal duplicate_category.id, backfill_outflow.reload.entryable.category_id
  end
end
