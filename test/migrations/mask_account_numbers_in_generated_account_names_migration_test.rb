# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261015200100_mask_account_numbers_in_generated_account_names")

class MaskAccountNumbersInGeneratedAccountNamesMigrationTest < ActiveSupport::TestCase
  setup do
    @questrade_account = questrade_accounts(:one)
    @account = accounts(:investment)
    AccountProvider.where(account: @account).delete_all
    AccountProvider.create!(account: @account, provider: @questrade_account)
  end

  test "masks the number in a generated provider name and its linked account" do
    @account.update_column(:name, "TFSA (12345678)")

    run_migration

    assert_equal "TFSA (•••5678)", @questrade_account.reload.name
    assert_equal "TFSA (•••5678)", @account.reload.name
  end

  test "keeps a user's own wording around the number" do
    @account.update_column(:name, "My savings TFSA (12345678)")

    run_migration

    assert_equal "My savings TFSA (•••5678)", @account.reload.name
  end

  test "leaves a renamed account without the number alone" do
    @account.update_column(:name, "Retirement")

    run_migration

    assert_equal "Retirement", @account.reload.name
  end

  test "masks a Fio default name" do
    fio_account = fio_accounts(:checking)

    run_migration

    assert_equal "Fio banka •••2222", fio_account.reload.name
  end

  test "keeps a user's own wording before a Fio default name" do
    fio_account = fio_accounts(:checking)
    account = accounts(:depository)
    AccountProvider.where(account: account).delete_all
    AccountProvider.create!(account: account, provider: fio_account)
    account.update_column(:name, "My savings Fio banka #{fio_account.fio_account_id}")

    run_migration

    assert_equal "My savings Fio banka •••#{fio_account.fio_account_id.last(4)}", account.reload.name
  end

  test "renames an Interactive Brokers record named after the bare id" do
    ibkr_account = ibkr_accounts(:main_account)
    ibkr_account.update_columns(name: ibkr_account.ibkr_account_id)

    run_migration

    assert_equal "Interactive Brokers (•••#{ibkr_account.ibkr_account_id.last(4)})", ibkr_account.reload.name
  end

  test "works through providers across several batches" do
    second = @questrade_account.dup
    second.update!(questrade_account_id: "87654321", name: "RRSP (87654321)")
    @account.update_column(:name, "TFSA (12345678)")
    migration = MaskAccountNumbersInGeneratedAccountNames.new
    migration.stubs(:batch_size).returns(1)

    run_migration(migration)

    assert_equal "TFSA (•••5678)", @questrade_account.reload.name
    assert_equal "TFSA (•••5678)", @account.reload.name
    assert_equal "RRSP (•••4321)", second.reload.name
  end

  private

    def run_migration(migration = MaskAccountNumbersInGeneratedAccountNames.new)
      ActiveRecord::Migration.suppress_messages do
        migration.up
      end
    end
end
