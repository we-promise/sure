module PairedTransferCategoryStreams
  extend ActiveSupport::Concern

  private
    # The other leg of a categorizable transfer shows this leg's category
    # read-only (Transaction#category_set_on_transfer_counterpart?), so
    # refresh it whenever this leg's category may have changed.
    def paired_transfer_category_stream_items(transaction)
      transfer = transaction.transfer
      return [] unless transfer&.categorizable? && transfer.category_transaction.id == transaction.id

      counterpart = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction : transfer.inflow_transaction
      %w[mobile desktop].map do |variant|
        turbo_stream.replace(
          helpers.dom_id(counterpart, "category_menu_#{variant}"),
          partial: "transactions/transaction_category",
          locals: { transaction: counterpart, variant: variant }
        )
      end + [
        turbo_stream.replace(
          "category_name_mobile_#{counterpart.id}",
          partial: "categories/category_name_mobile",
          locals: { transaction: counterpart }
        )
      ]
    end
end
