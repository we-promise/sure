module Family::MyfundConnectable
  extend ActiveSupport::Concern

  included do
    has_many :myfund_items, dependent: :destroy
  end

  def has_myfund_credentials?
    myfund_items.where.not(api_key: nil).exists?
  end
end
