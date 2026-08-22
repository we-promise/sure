require "test_helper"
require "ostruct"

class ImportsHelperTest < ActionView::TestCase
  test "dry run resource labels come from locale keys" do
    %i[
      transactions balances accounts categories tags rules merchants
      recurring_transactions transfers rejected_transfers trades holdings
      valuations budgets budget_categories
    ].each do |key|
      assert_equal I18n.t("imports.dry_run_resources.#{key}"), dry_run_resource(key).label
    end

    balances = dry_run_resource(:balances)
    assert_equal "line-chart", balances.icon
    assert_equal "text-secondary", balances.text_class
    assert_equal "bg-container-inset", balances.bg_class

    resources = %i[
      transactions balances accounts categories tags rules merchants
      recurring_transactions transfers rejected_transfers trades holdings
      valuations budgets budget_categories
    ].map { |key| dry_run_resource(key) }
    resources.each do |resource|
      refute_match(/\b(?:text|bg)-[a-z]+-\d{2,3}/, [ resource.text_class, resource.bg_class ].join(" "))
    end
  end

  test "import verification view handles missing readback payload" do
    import = OpenStruct.new(verification_payload: {})

    verification = import_verification_view(import)

    assert_equal "not_verified", verification.status
    assert_equal 0, verification.checked_total
    assert_equal 0, verification.mismatches_count
    assert_empty verification.mismatches_preview
    refute verification.mismatches?
  end

  test "import verification view handles nil readback payload" do
    import = OpenStruct.new(verification_payload: { readback: nil })

    verification = import_verification_view(import)

    assert_equal "not_verified", verification.status
    assert_equal 0, verification.checked_total
    assert_equal 0, verification.mismatches_count
    assert_empty verification.mismatches_preview
    refute verification.mismatches?
  end

  test "import verification view shapes readback counts and mismatch preview" do
    import = OpenStruct.new(
      verification_payload: {
        readback: {
          status: "mismatch",
          checked_counts: { accounts: 1, transactions: "2" },
          mismatches: {
            accounts: { expected: 1, actual: 0 },
            transactions: { expected: 2, actual: 1 },
            categories: { expected: 3, actual: 2 },
            tags: { expected: 4, actual: 3 }
          }
        }
      }
    )

    verification = import_verification_view(import)

    assert_equal "mismatch", verification.status
    assert_equal 3, verification.checked_total
    assert_equal 4, verification.mismatches_count
    assert_equal %w[accounts transactions categories], verification.mismatches_preview.map(&:first)
    assert verification.mismatches?
  end
end
