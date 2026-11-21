# carried_forward: the importer filled this date by repeating an earlier
# price; a real quote is carried_forward: false. provisional: a recent
# carried-forward price the importer asks the provider for again. Every
# provisional row is carried forward (provisional rows stored before the
# column existed were backfilled), so readers of real quotes filter on
# carried_forward alone.
class Security::Price < ApplicationRecord
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }
end
