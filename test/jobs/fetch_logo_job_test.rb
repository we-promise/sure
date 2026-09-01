# frozen_string_literal: true

require "test_helper"

class FetchLogoJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:depository)
    @account.update!(institution_domain: "example.com", logo_source: "auto")
  end

  test "delegates fetching to Account::LogoFetcher" do
    fetcher_mock = mock
    fetcher_mock.expects(:fetch_and_attach).once
    Account::LogoFetcher.expects(:new).with(@account, expected_domain: "example.com").returns(fetcher_mock)

    FetchLogoJob.perform_now(@account.id, "example.com")
  end

  test "skips when account not found" do
    Account::LogoFetcher.expects(:new).never

    FetchLogoJob.perform_now("non-existent-id")
  end

  test "skips when logo_source is manual" do
    @account.update!(logo_source: "manual")
    Account::LogoFetcher.expects(:new).never

    FetchLogoJob.perform_now(@account.id)
  end

  test "skips when institution_domain is blank" do
    @account.update!(institution_domain: nil)
    Account::LogoFetcher.expects(:new).never

    FetchLogoJob.perform_now(@account.id)
  end
end
