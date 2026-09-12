module Family::OpenBankingIoConnectable
  extend ActiveSupport::Concern

  included do
    # Named *_items so Family::Syncer's reflection picks the connection up for family syncs.
    has_many :open_banking_io_items, dependent: :destroy
  end

  def can_connect_open_banking_io?
    true
  end
end
