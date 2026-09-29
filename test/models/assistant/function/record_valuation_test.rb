require "test_helper"

class Assistant::Function::RecordValuationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:other_asset)
    @function = Assistant::Function::RecordValuation.new(@user)
    @source = "Appraisal report 2024-06-30 (grade: A)"
  end

  test "records a valuation and stores the citation on the entry" do
    result = nil

    assert_difference "@account.entries.valuations.count", 1 do
      result = @function.call(params)
    end

    assert result[:success]
    assert_not result[:replaced_existing]
    assert_equal "A", result[:provenance][:grade]

    entry = Entry.find(result[:entry_id])
    assert_equal @source, entry.notes
    assert_equal 1234.56.to_d, entry.amount
  end

  test "flags when an existing valuation on the same date is replaced" do
    @function.call(params)

    result = @function.call(params(amount: 2000))

    assert result[:success]
    assert result[:replaced_existing]
  end

  test "preserves a human note when replacing a valuation" do
    first = @function.call(params)
    Entry.find(first[:entry_id]).update!(notes: "Appraiser said the roof needs work")

    result = @function.call(params(amount: 2000))

    notes = Entry.find(result[:entry_id]).notes
    assert_includes notes, "Appraiser said the roof needs work"
    assert_includes notes, @source
  end

  test "re-recording with the same citation does not stack it" do
    @function.call(params)
    @function.call(params(amount: 2000))
    result = @function.call(params(amount: 3000))

    notes = Entry.find(result[:entry_id]).notes
    assert_equal @source, notes
  end

  test "appends a changed citation so the provenance trail survives" do
    first = @function.call(params)
    revised = "Revised appraisal 2024-07-15 (grade: A)"

    result = @function.call(params(source: revised))

    notes = Entry.find(result[:entry_id]).notes
    assert_includes notes, @source
    assert_includes notes, revised
    assert_equal first[:entry_id], result[:entry_id]
  end

  test "rejects a citation that does not follow the grammar" do
    result = @function.call(params(source: "estimated: pulled from a spreadsheet"))

    assert_not result[:success]
    assert_equal "invalid_source_citation", result[:error]
    assert_match(/reliability grade/, result[:message])
  end

  test "rejects a missing citation" do
    result = @function.call(params(source: ""))

    assert_not result[:success]
    assert_equal "invalid_source_citation", result[:error]
  end

  test "reports a failed reconciliation and creates no entry" do
    failure = OpenStruct.new(success?: false, error_message: "Balance is invalid")
    Account.any_instance.stubs(:create_reconciliation).returns(failure)

    result = nil
    assert_no_difference "@account.entries.valuations.count" do
      result = @function.call(params)
    end

    assert_not result[:success]
    assert_equal "valuation_failed", result[:error]
    assert_equal "Balance is invalid", result[:message]
  end

  test "rejects an unparseable date" do
    result = @function.call(params(date: "June 30th"))

    assert_not result[:success]
    assert_equal "invalid_date", result[:error]
  end

  test "rejects a non-numeric amount" do
    result = @function.call(params(amount: "a lot"))

    assert_not result[:success]
    assert_equal "invalid_amount", result[:error]
  end

  test "rejects an account the user cannot write to" do
    result = Assistant::Function::RecordValuation.new(users(:family_member)).call(params)

    assert_not result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "accepts an estimated citation carrying a grade" do
    result = @function.call(params(source: "estimated: linear interpolation over 2024-01 / 2024-12 anchors (grade: C)"))

    assert result[:success]
    assert result[:provenance][:estimated]
    assert_equal "C", result[:provenance][:grade]
  end

  private
    def params(overrides = {})
      {
        "account_id" => @account.id,
        "date" => "2024-06-30",
        "amount" => 1234.56,
        "source" => @source
      }.merge(overrides.transform_keys(&:to_s))
    end
end
