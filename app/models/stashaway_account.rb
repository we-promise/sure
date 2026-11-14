# One Sure account's worth of StashAway portfolios: those with the same
# name, funding source and goal type when first seen, such as an archived
# and an active "Simple SGD" portfolio. A portfolio stays with its account
# when renamed; the account is named after its leading portfolio.
class StashawayAccount < ApplicationRecord
  include Encryptable

  SOURCE = "stashaway".freeze

  # Goal types whose portfolios hold cash or money-market funds rather than
  # an invested portfolio.
  CASH_LIKE_GOAL_TYPE = /SIMPLE|MMF|CASH|FIXED|GUARANTEED/i

  if encryption_ready?
    encrypts :raw_goals_payload
  end

  belongs_to :stashaway_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :group_key, presence: true
  validates :currency, presence: true

  before_save :remember_goal_ids, if: :raw_goals_payload_changed?

  class << self
    # The portfolios that belong together, by their names' letters and
    # digits in any script. A name that is only emoji or punctuation keeps
    # its own group. An account's key is its leading
    # portfolio's, so it follows a rename, and two accounts can come to share
    # one; a portfolio not held yet then joins the older.
    def group_key_for(name:, funding_source:, goal_type:, fallback:)
      normalized = name.to_s.unicode_normalize(:nfkd).downcase.gsub(/[^\p{L}\p{N} ]+/, " ").squeeze(" ").strip
      [ normalized.presence || fallback, funding_source, goal_type ].join("|")
    end
  end

  def current_account
    account || linked_account
  end

  def goals
    raw_goals_payload.is_a?(Array) ? raw_goals_payload : []
  end

  def cash_like?
    goal_type.to_s.match?(CASH_LIKE_GOAL_TYPE)
  end

  def accountable_type
    cash_like? ? "Depository" : "Investment"
  end

  def accountable_subtype
    return "savings" if cash_like?

    funding_source.to_s.casecmp?("SRS") ? "retirement" : "brokerage"
  end

  def linkable_to?(account)
    account.accountable_type.in?(%w[Investment Depository])
  end

  # Links the Sure account and fixes where importing into it starts: the day
  # after the last entry from anywhere else, so history it already holds,
  # such as statement imports, stays as it is. The balance the import
  # measures from (import_base) is fixed by the first import; one left by an
  # earlier link is dropped.
  def link_to!(account)
    transaction do
      start = StashawayAccount::ImportStart.new(self, account).date
      AccountProvider.create!(account: account, provider: self)
      update!(import_start_date: start, import_base: nil)
    end

    reload_account_provider
  end

  private

    # The ids of the portfolios held, kept apart from their stored detail so
    # the importer can tell which account a portfolio belongs to without
    # reading every account's goals.
    def remember_goal_ids
      self.goal_ids = goals.map { |goal| goal["id"].to_s }
    end
end
