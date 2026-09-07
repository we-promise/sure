require "test_helper"

# The mutation gate (`loans:verify_contract_mutations`) is only as good as its
# anchors: a `find` string that no longer matches the production file mutates
# nothing, and the row's tests then "survive" for a reason that has nothing to
# do with the contract. The gate aborts when that happens, but it takes minutes
# to run and nothing forces it. This runs in the normal suite instead, so a
# refactor that moves an anchor fails immediately and next to the change.
class Loan::ContractMutationManifestTest < ActiveSupport::TestCase
  MUTATIONS = YAML.load_file(Rails.root.join("config/loan_contract_mutations.yml")).freeze
  CONTRACT_ROWS = (1..16).map { |number| "C#{number}" }.freeze

  test "every contract row has a mutation" do
    assert_equal CONTRACT_ROWS, MUTATIONS.keys.sort_by { |id| id.delete_prefix("C").to_i }
  end

  test "every mutation anchor matches its production file exactly once" do
    MUTATIONS.each do |id, mutation|
      path = Rails.root.join(mutation.fetch("file"))
      assert path.file?, "#{id}: #{mutation.fetch('file')} does not exist"

      occurrences = path.read.scan(mutation.fetch("find")).length
      assert_equal 1, occurrences,
        "#{id}: anchor matches #{occurrences} times in #{mutation.fetch('file')}; a mutation that matches nothing proves nothing"
    end
  end

  test "every mutation changes the source it targets" do
    MUTATIONS.each do |id, mutation|
      assert_not_equal mutation.fetch("find"), mutation.fetch("replace"),
        "#{id}: replacement is identical to the anchor, so the mutation is a no-op"
      assert mutation.fetch("defect").present?, "#{id}: mutation must describe the defect it injects"
    end
  end

  test "mutations target production code, not tests" do
    MUTATIONS.each do |id, mutation|
      assert_match %r{\Aapp/}, mutation.fetch("file"),
        "#{id}: mutating a test would prove the test can be broken, not that it pins behaviour"
    end
  end
end
