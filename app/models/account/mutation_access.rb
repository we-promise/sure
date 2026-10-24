class Account::MutationAccess
  READ = :read
  ANNOTATE = :annotate
  WRITE = :write
  OWNER = :owner
  LEVELS = [ READ, ANNOTATE, WRITE, OWNER ].freeze

  ALLOWED_PERMISSIONS = {
    READ => [ :owner, :full_control, :read_write, :read_only ],
    ANNOTATE => [ :owner, :full_control, :read_write ],
    WRITE => [ :owner, :full_control ],
    OWNER => [ :owner ]
  }.freeze

  class Denied < StandardError; end

  def self.lock!(accounts:, user:, level:)
    raise ArgumentError, "unknown access level: #{level}" unless level.in?(LEVELS)
    raise ArgumentError, "mutation access must be acquired inside a transaction" unless Account.connection.transaction_open?

    ids = Array(accounts).compact.map(&:id).uniq.sort
    raise Denied, "no accounts supplied" if ids.empty?

    locked_accounts = Account.where(id: ids).order(:id).to_a
    raise Denied, "account set changed" unless locked_accounts.map(&:id) == ids
    locked_accounts.each(&:lock!)
    raise Denied, "account belongs to another family" unless locked_accounts.all? { |account| account.family_id == user.family_id }

    shares = AccountShare.where(account_id: ids, user_id: user.id).order(:account_id).lock.index_by(&:account_id)
    allowed = ALLOWED_PERMISSIONS.fetch(level)

    locked_accounts.each do |account|
      permission = account.owner_id == user.id ? :owner : shares[account.id]&.permission&.to_sym
      raise Denied, "account access changed" unless permission.in?(allowed)
    end

    locked_accounts.to_h { |account| [ account.id.to_s, account ] }
  end
end
