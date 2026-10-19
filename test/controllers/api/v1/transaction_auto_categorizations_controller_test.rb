# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionAutoCategorizationsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @uncategorized = create_transaction(account: @account, name: "Corner cafe").transaction

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    Family.any_instance.stubs(:resolved_categorization_provider).returns(OpenStruct.new(name: "llm"))
  end

  test "queues the requested uncategorized transactions" do
    assert_enqueued_with(job: AutoCategorizeJob, args: [ @family, { transaction_ids: [ @uncategorized.id ] } ]) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: [ @uncategorized.id ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal 1, body["queued_count"]
    assert_equal [ @uncategorized.id ], body["transaction_ids"]
    assert_equal [], body["skipped_transaction_ids"]
  end

  test "queues every eligible transaction when no ids are given" do
    post auto_categorize_api_v1_transactions_url, headers: api_headers(@api_key), as: :json

    assert_response :accepted
    body = JSON.parse(response.body)
    expected = @family.auto_categorizable_transactions_for(@user).pluck(:id)
    assert_includes body["transaction_ids"], @uncategorized.id
    assert_equal expected.sort, body["transaction_ids"].sort
    assert_equal body["transaction_ids"].size, body["queued_count"]
  end

  test "batches jobs at the provider's per-call limit" do
    Provider::LlmConcept.stubs(:max_items_per_call).returns(1)
    other = create_transaction(account: @account, name: "Hardware store").transaction

    assert_enqueued_jobs 2, only: AutoCategorizeJob do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: [ @uncategorized.id, other.id ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :accepted
  end

  test "skips categorized, locked, transfer and split parent transactions" do
    categorized = create_transaction(account: @account, category: categories(:food_and_drink)).transaction
    locked = create_transaction(account: @account, name: "Left blank on purpose").transaction
    locked.lock_attr!(:category_id)
    transfer_leg = create_transaction(account: @account, kind: "funds_movement").transaction
    split_parent = create_transaction(account: @account, amount: 100).transaction
    split_parent.entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])

    requested = [ categorized, locked, transfer_leg, split_parent ].map(&:id)

    assert_no_enqueued_jobs(only: AutoCategorizeJob) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: requested },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal 0, body["queued_count"]
    assert_equal requested.sort, body["skipped_transaction_ids"].sort
  end

  test "skips transactions from another family" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = create_transaction(account: other_account).transaction

    assert_no_enqueued_jobs(only: AutoCategorizeJob) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: [ foreign.id ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :accepted
    assert_equal [ foreign.id ], JSON.parse(response.body)["skipped_transaction_ids"]
  end

  test "skips transactions on accounts the user may only read" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    member_key = ApiKey.create!(user: member, name: "Member Key", scopes: [ "read_write" ], display_key: "test_member_#{SecureRandom.hex(8)}")
    shared = @family.accounts.create!(name: "Shared read-only", balance: 0, currency: "USD", accountable: Depository.new, owner: @user)
    shared.share_with!(member, permission: "read_only")
    read_only = create_transaction(account: shared).transaction

    assert_no_enqueued_jobs(only: AutoCategorizeJob) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: [ read_only.id ] },
           headers: api_headers(member_key), as: :json
    end

    assert_response :accepted
    assert_equal [ read_only.id ], JSON.parse(response.body)["skipped_transaction_ids"]
  end

  test "returns 422 when no categorization provider is configured" do
    Family.any_instance.stubs(:resolved_categorization_provider).returns(nil)

    assert_no_enqueued_jobs(only: AutoCategorizeJob) do
      post auto_categorize_api_v1_transactions_url, headers: api_headers(@api_key), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "returns 422 when the family has no categories" do
    @family.categories.destroy_all

    assert_no_enqueued_jobs(only: AutoCategorizeJob) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: [ @uncategorized.id ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_match(/no categories/, body["message"])
  end

  test "treats uppercase ids as the same transaction" do
    assert_enqueued_with(job: AutoCategorizeJob, args: [ @family, { transaction_ids: [ @uncategorized.id ] } ]) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: [ @uncategorized.id.upcase, @uncategorized.id ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal [ @uncategorized.id ], body["transaction_ids"]
    assert_equal [], body["skipped_transaction_ids"]
  end

  test "returns 422 for malformed transaction_ids" do
    [ [], "not-an-array", [ "not-a-uuid" ] ].each do |ids|
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: ids },
           headers: api_headers(@api_key), as: :json

      assert_response :unprocessable_entity, "expected 422 for #{ids.inspect}"
    end
  end

  test "returns 422 when too many ids are sent" do
    max_ids = Api::V1::TransactionAutoCategorizationsController::MAX_TRANSACTION_IDS
    ids = Array.new(max_ids + 1) { SecureRandom.uuid }

    post auto_categorize_api_v1_transactions_url,
         params: { transaction_ids: ids },
         headers: api_headers(@api_key), as: :json

    assert_response :unprocessable_entity
  end

  test "counts duplicate ids toward the limit" do
    max_ids = Api::V1::TransactionAutoCategorizationsController::MAX_TRANSACTION_IDS
    ids = Array.new(max_ids + 1, @uncategorized.id)

    assert_no_enqueued_jobs(only: AutoCategorizeJob) do
      post auto_categorize_api_v1_transactions_url,
           params: { transaction_ids: ids },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :unprocessable_entity
  end

  test "requires the read_write scope" do
    post auto_categorize_api_v1_transactions_url, headers: api_headers(@read_only_api_key), as: :json
    assert_response :forbidden
  end

  test "requires authentication" do
    post auto_categorize_api_v1_transactions_url, as: :json
    assert_response :unauthorized
  end
end
