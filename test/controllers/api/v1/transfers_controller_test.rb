# frozen_string_literal: true

require "test_helper"

class Api::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)

    @rw_api_key = api_keys(:active_key) # pipelock:ignore Credential in URL
    @ro_api_key = api_keys(:read_only_key) # pipelock:ignore Credential in URL

    @source_account = accounts(:depository)
    @destination_account = accounts(:credit_card)
  end

  # Create action tests
  test "create requires authentication" do
    post api_v1_transfers_url, params: {
      transfer: {
        source_account_id: @source_account.id,
        destination_account_id: @destination_account.id,
        date: Date.current.to_s,
        amount: "100.00"
      }
    }

    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    post api_v1_transfers_url,
         params: {
           transfer: {
             source_account_id: @source_account.id,
             destination_account_id: @destination_account.id,
             date: Date.current.to_s,
             amount: "100.00"
           }
         },
         headers: api_headers(@ro_api_key)

    assert_response :forbidden
  end

  test "create transfer successfully" do
    assert_difference -> { Transfer.count }, 1 do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: @source_account.id,
               destination_account_id: @destination_account.id,
               date: Date.current.to_s,
               amount: "150.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :created

    transfer = JSON.parse(response.body)
    assert transfer["id"].present?
    assert_equal @source_account.id, transfer["source_account"]["id"]
    assert_equal @source_account.name, transfer["source_account"]["name"]
    assert_equal @destination_account.id, transfer["destination_account"]["id"]
    assert_equal @destination_account.name, transfer["destination_account"]["name"]
    assert_equal Date.current.to_s, transfer["date"]
    assert_equal "150.0", transfer["amount"]
    assert_equal "confirmed", transfer["status"]
    assert transfer["created_at"].present?
    assert transfer["updated_at"].present?
  end

  test "create returns 404 for non-existent source account" do
    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: SecureRandom.uuid,
               destination_account_id: @destination_account.id,
               date: Date.current.to_s,
               amount: "100.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :not_found
  end

  test "create returns 404 for non-existent destination account" do
    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: @source_account.id,
               destination_account_id: SecureRandom.uuid,
               date: Date.current.to_s,
               amount: "100.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :not_found
  end

  test "create returns 404 for destination account from another family" do
    other_account = Account.create!(
      family: families(:empty), name: "Other Account", currency: "USD",
      balance: 100, accountable: Depository.new
    )

    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: @source_account.id,
               destination_account_id: other_account.id,
               date: Date.current.to_s,
               amount: "100.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :not_found
  end

  test "create returns 404 for source account from another family" do
    other_account = Account.create!(
      family: families(:empty), name: "Other Account", currency: "USD",
      balance: 100, accountable: Depository.new
    )

    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: other_account.id,
               destination_account_id: @destination_account.id,
               date: Date.current.to_s,
               amount: "100.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :not_found
  end

  test "create returns 404 for account from another family" do
    other_family = families(:empty)
    other_account = Account.create!(
      family: other_family, name: "Other Account", currency: "USD",
      balance: 100, accountable: Depository.new
    )

    post api_v1_transfers_url,
         params: {
           transfer: {
             source_account_id: @source_account.id,
             destination_account_id: other_account.id,
             date: Date.current.to_s,
             amount: "100.00"
           }
         },
         headers: api_headers(@rw_api_key)

    assert_response :not_found
  end

  test "create returns 422 for invalid date" do
    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: @source_account.id,
               destination_account_id: @destination_account.id,
               date: "not-a-date",
               amount: "100.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :unprocessable_entity
  end

  test "create returns 422 for same source and destination account" do
    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: {
             transfer: {
               source_account_id: @source_account.id,
               destination_account_id: @source_account.id,
               date: Date.current.to_s,
               amount: "100.00"
             }
           },
           headers: api_headers(@rw_api_key)
    end

    assert_response :unprocessable_entity
  end

  private

    def api_headers(key)
      { "X-Api-Key" => key.display_key }
    end
end
