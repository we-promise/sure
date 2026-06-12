# frozen_string_literal: true

require "test_helper"

class IndexaCapitalActivitiesFetchJobTest < ActiveSupport::TestCase
  test "sidekiq lock key uses stable account id" do
    indexa_capital_account = indexa_capital_accounts(:mutual_fund)
    options = sidekiq_options
    lock_args_method = options.fetch("lock_args_method") { options.fetch(:lock_args_method) }

    assert_equal [ indexa_capital_account.id ], lock_args_method.call([ indexa_capital_account ])
  end

  private

    def sidekiq_options
      if IndexaCapitalActivitiesFetchJob.respond_to?(:get_sidekiq_options)
        IndexaCapitalActivitiesFetchJob.get_sidekiq_options
      else
        IndexaCapitalActivitiesFetchJob.sidekiq_options_hash
      end
    end
end
