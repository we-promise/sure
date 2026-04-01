class SettleMaturedBondLotsJob < ApplicationJob
  queue_as :scheduled

  def perform(on: Date.current)
    BondLot.open
      .where(auto_close_on_maturity: true)
      .where("maturity_date <= ?", on)
      .find_each do |lot|
        lot.settle_if_matured!(on:)
      rescue StandardError => e
        Rails.logger.error(
          "SettleMaturedBondLotsJob failed for lot_id=#{lot.id} account_id=#{lot.account.id}: #{e.class}: #{e.message}"
        )
      end
  end
end
