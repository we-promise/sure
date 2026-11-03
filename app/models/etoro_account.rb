class EtoroAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_trades_payload
    encrypts :raw_balance_history_payload
  end

  belongs_to :etoro_item

  # A copy-trading mirror shown as an account of its own, beside the eToro
  # account it belongs to (see EtoroAccount::CopiesProcessor). Its positions
  # and history are the main account's, kept there.
  belongs_to :main_account, class_name: "EtoroAccount", optional: true
  has_many :copy_accounts, class_name: "EtoroAccount", foreign_key: :main_account_id, inverse_of: :main_account, dependent: :destroy
  has_many :portfolio_snapshots, class_name: "EtoroPortfolioSnapshot", dependent: :delete_all

  # How the account shows in Sure. As holdings, each security eToro holds is
  # a holding and each position's opening and closes are trades. As totals,
  # the account follows eToro's daily total and cash, and whatever is not cash
  # is one holding (see EtoroAccount::TotalsProcessor). As copies, each
  # copy-trading mirror is an account of its own and this one keeps the rest
  # (see EtoroAccount::CopiesProcessor). A change takes effect on the next
  # sync, which rebuilds the account from the stored payloads. A copy account
  # is always shown as copies.
  enum :display_mode, { holdings: "holdings", totals: "totals", copies: "copies" }, prefix: :shown_as, default: :holdings, validate: true

  scope :main_accounts, -> { where(main_account_id: nil) }

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :etoro_account_id, uniqueness: { scope: :etoro_item_id, allow_nil: true }
  validates :mirror_id, presence: true, if: :main_account_id?

  def current_account
    account || linked_account
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "EtoroAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "EtoroAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "etoro",
      family: etoro_item.family,
      provider_key: "etoro"
    )
    nil
  end

  def instruments_map
    etoro_item.instruments_map
  end

  # Whether a change of how the account shows can take effect. The sync that
  # makes it leaves out a linked account that is disabled or being deleted
  # (EtoroItem#process_accounts).
  def display_mode_changeable?
    account = current_account
    account.nil? || !(account.disabled? || account.pending_deletion?)
  end

  # Whether `user` may change how the account shows: write access to each
  # account a change from the current mode writes to, as linking one takes.
  # A change to copies also writes to the copy accounts; that one is checked
  # once it is asked for.
  def display_mode_changeable_by?(user)
    display_mode_changeable? && display_mode_accounts.all? { |account| account.permission_for(user).in?([ :owner, :full_control ]) }
  end

  # The Sure accounts a change of how the account shows to `mode` writes to:
  # the linked account, and the copy accounts when the change leaves or
  # enters copies, which empties or rebuilds them (see
  # EtoroAccount::Processor). A copy account being deleted is left out, as
  # the sync is.
  def display_mode_accounts(mode = display_mode)
    copies = copy_accounts.includes(account_provider: :account).filter_map(&:shown_account) if shown_as_copies? || mode.to_s == "copies"
    [ current_account, *copies ].compact
  end

  def copy?
    main_account_id.present?
  end

  # Whether the account is split into a main account and one per copy, as
  # its main account's setting says for a copy account.
  def split_into_copies?
    copy? ? main_account&.shown_as_copies? || false : shown_as_copies?
  end

  # The account whose payloads hold the positions: a copy's main account.
  def positions_owner
    copy? ? main_account : self
  end

  # The open positions this account shows: a copy's mirror's, and for the
  # main account all of eToro's, or only those the user opened when split
  # into copies.
  def held_positions
    positions = Array(positions_owner&.raw_positions_payload)
    return positions unless copy? || shown_as_copies?

    part = copy? ? mirror_id.to_i : EtoroPortfolioSnapshot::OWN_POSITIONS
    positions.select { |position| position_mirror_id(position) == part }
  end

  # The first day Sure recorded a copy's mirror, where its history starts.
  def copy_recorded_since
    copy_snapshots&.minimum(:date)
  end

  # The day a copy was found closed, while it is.
  def copy_closed_on
    latest = copy_snapshots&.order(date: :desc)&.first
    latest.date if latest&.closed?
  end

  # The account's own linked Sure account, unless it is being deleted. A
  # disabled one still counts: net worth leaves it out from the day it was
  # disabled, as for any disabled account, and counts its history before.
  def shown_account
    account = current_account
    account unless account.nil? || account.pending_deletion?
  end

  # Whether a sync processes the account while its Sure account is disabled.
  # Net worth counts a disabled account on the days before it was disabled,
  # and a split main account leaves out every copy set up as an account,
  # disabled or not, so a disabled copy follows its main account where the
  # two would no longer add up: it is emptied once the main account is no
  # longer split, as that then counts the copy's positions, and rebuilt when
  # the main account is split again while the copy's account holds none of
  # the days or holdings Sure recorded of the copy.
  def processed_while_disabled?
    return false unless copy?
    return true unless split_into_copies?

    account = current_account
    account.present? && account.entries.where(source: "etoro", entryable_type: "Valuation").none? && account.holdings.none?
  end

  private

    def copy_snapshots
      main_account&.portfolio_snapshots&.where(mirror_id: mirror_id) if copy?
    end

    def position_mirror_id(position)
      key = position.keys.find { |candidate| candidate.to_s.casecmp?("mirrorID") } if position.is_a?(Hash)
      key ? position[key].to_i : EtoroPortfolioSnapshot::OWN_POSITIONS
    end
end
