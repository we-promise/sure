class Security < ApplicationRecord
  include Provided, PlanRestrictionTracker

  # Transient attribute for search results -- not persisted
  attr_accessor :search_currency, :search_isin

  # ISO 10383 MIC codes mapped to user-friendly exchange names
  # Source: https://www.iso20022.org/market-identifier-codes
  # Data stored in config/exchanges.yml
  EXCHANGES = YAML.safe_load_file(Rails.root.join("config", "exchanges.yml")).freeze

  # Legacy non-ISO values previously persisted as exchange_operating_mic
  # (e.g. raw EODHD exchange codes) mapped to their ISO MIC.
  MIC_ALIASES = {
    "WAR" => "XWAR",
    "GER" => "XETR", # Yahoo search code for Xetra, stored before it was mapped
    # Yahoo search codes for Canadian venues, stored before they were mapped
    "VAN" => "XTSX", "CNQ" => "XCNQ", "NEO" => "NEOE",
    # Raw EODHD codes that Provider::Eodhd still accepts for rows stored before it mapped them
    "F" => "XFRA", "BR" => "XBRU", "LS" => "XLIS", "VI" => "XWBO", "IR" => "XDUB",
    "BE" => "XBER", "DU" => "XDUS", "HM" => "XHAM", "HA" => "XHAN", "MU" => "XMUN", "STU" => "XSTU"
  }.freeze

  KINDS = %w[standard cash].freeze

  # Known securities provider keys — derived from the registry so adding a new
  # provider to Registry#available_providers automatically allows it here.
  # Evaluated at runtime (not boot) so runtime-enabled providers are accepted.
  def self.valid_price_providers
    Provider::Registry.for_concept(:securities).provider_keys.map(&:to_s)
  end

  # Builds the Brandfetch crypto URL for a base asset (e.g. "BTC"). Returns
  # nil when Brandfetch isn't configured.
  # The symbol goes into a URL path segment, and it comes from provider data —
  # an on-chain token can be called anything its deployer chose. A slash, a
  # question mark or a hash would not merely break the link: they would point
  # the path elsewhere on the CDN, or push the client id into a fragment where
  # Brandfetch never sees it. Guarded here rather than at each call site, since
  # six of them reach this method from four different providers.
  SAFE_CRYPTO_SYMBOL = /\A[A-Za-z0-9][A-Za-z0-9.\-]{0,31}\z/

  def self.brandfetch_crypto_url(base_asset)
    return nil if base_asset.blank?
    return nil unless base_asset.to_s.match?(SAFE_CRYPTO_SYMBOL)

    Setting.brand_fetch_icon_url(base_asset, namespace: "crypto")
  end

  # Classification taxonomy: the six-class / twelve-sub-class scheme other
  # portfolio trackers use, so an import maps onto it without a translation
  # table. The database enforces the same sets (chk_securities_asset_class,
  # chk_securities_asset_sub_class, chk_securities_classification_source);
  # adding a value means changing both, deliberately.
  #
  # `apply_classification_defaults` fills the two kinds a provider cannot
  # answer (cash, crypto) and `apply_default_region` fills the region;
  # everything else stays unclassified (NULL) until a provider, the user or an
  # approved proposal answers it.
  #
  # The migration repeats these lists rather than reading them from here, so
  # that it produces the same schema whenever it runs. Changing a list is
  # therefore a two-file edit, and "the model taxonomy and the database
  # constraint list the same values" fails if only one side moves.
  #
  # `sector` and `industry` have no constants and no validation on purpose:
  # they hold provider vocabulary, which no two providers agree on. An
  # `inclusion` rule there would reject a value a provider legitimately
  # returns.
  #
  # `region` is NOT the same case, and grouping it with those two would be
  # wrong. No provider supplies a region -- they supply a country, and the
  # region is derived from it against a list this application owns -- so its
  # vocabulary is closed and a model-level `inclusion` validation is the right
  # enforcement; REGION_KEYS below is that list. It is left unconstrained in
  # the DATABASE for a different reason: the list belongs in configuration,
  # where widening it should not need a migration. The migration header says
  # the same.
  ASSET_CLASSES = %w[
    alternative_investment commodity equity fixed_income liquidity real_estate
  ].freeze

  ASSET_SUB_CLASSES = %w[
    bond cash collectible commodity cryptocurrency etf loan mutual_fund
    precious_metal private_equity real_estate stock
  ].freeze

  # Same shape as Holding's cost-basis provenance: who set the classification,
  # so a later writer knows whether it may replace it. `classification_locked`
  # is the user's veto over every source.
  CLASSIFICATION_SOURCES = %w[provider manual ai default].freeze

  # Country code -> portfolio region and developed/emerging. Data in
  # config/regions.yml, which carries the reasoning for the five-region split
  # and for the developed/emerging calls the index families disagree on.
  #
  # `region` has no check constraint -- unlike asset class and sub-class -- so
  # the vocabulary is held here rather than in the database. REGION_KEYS is
  # what keeps it a vocabulary at all: a test asserts the config uses those
  # five and nothing else, so a typo in a new country's entry fails rather
  # than quietly creating a sixth region that an allocation chart would show
  # as its own slice.
  REGIONS = YAML.safe_load_file(Rails.root.join("config", "regions.yml")).freeze

  # Snake_case keys, like ASSET_CLASSES and ASSET_SUB_CLASSES, so the label a
  # user sees is a translation rather than the stored value.
  REGION_KEYS = %w[
    north_america europe asia_pacific latin_america middle_east_africa
  ].freeze

  before_validation :upcase_symbols
  # Declared after :upcase_symbols deliberately -- `crypto?` compares against a
  # canonical MIC, and that callback is what canonicalises it.
  before_validation :apply_classification_defaults
  before_save :apply_default_region, unless: :classification_locked?
  before_save :generate_logo_url_from_brandfetch, if: :should_generate_logo?
  before_save :reset_first_provider_price_on_if_provider_changed

  has_many :trades, dependent: :nullify, class_name: "Trade"
  has_many :prices, dependent: :destroy
  has_many :splits, dependent: :destroy
  # A security row is shared by every family that holds the instrument, but a
  # Tag belongs to one family, so a tagging is reachable only through its
  # owning family's tags. Read one family's with #tags_for and write them with
  # #set_tags_for. There is deliberately no `has_many :tags, through:`: its
  # generated `tags=`, `tag_ids=` and `tags <<` know nothing about families,
  # and would delete other families' taggings or attach a tag the family does
  # not own.
  has_many :taggings, as: :taggable, dependent: :destroy
  # One DELETE: a world fund lists thousands of rows, and Security::Constituent
  # has no callbacks for a per-row destroy to run.
  has_many :constituents, class_name: "Security::Constituent", dependent: :delete_all
  has_many :classification_proposals, class_name: "Security::ClassificationProposal", dependent: :delete_all

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :exchange_operating_mic, case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }
  validates :price_provider, inclusion: { in: ->(_) { Security.valid_price_providers } }, allow_nil: true
  validates :asset_class, inclusion: { in: ASSET_CLASSES }, allow_nil: true
  validates :asset_sub_class, inclusion: { in: ASSET_SUB_CLASSES }, allow_nil: true
  validates :classification_source, inclusion: { in: CLASSIFICATION_SOURCES }, allow_nil: true
  # `region` has no check constraint, so this is the only thing keeping it a
  # vocabulary rather than free text. Nil is allowed: a country the config does
  # not name leaves the region unanswered rather than guessed. A blank is no
  # answer either, so it becomes nil before validation and the country fills it.
  normalizes :region, with: ->(value) { value.presence }
  validates :region, inclusion: { in: REGION_KEYS }, allow_nil: true

  scope :online, -> { where(offline: false) }
  scope :standard, -> { where(kind: "standard") }

  # Parses the combobox ID format "SYMBOL|EXCHANGE|PROVIDER" into a hash.
  def self.parse_combobox_id(value)
    parts = value.to_s.split("|", 3)
    { ticker: parts[0].presence, exchange_operating_mic: parts[1].presence, price_provider: parts[2].presence }
  end

  # Lazily finds or creates a synthetic cash security for an account.
  # Used as fallback when creating an interest Trade without a user-selected
  # security, and to represent non-primary-currency cash positions as holdings
  # (issue #1809). When a currency that differs from the account's primary
  # currency is given, a distinct per-currency security is created so balances
  # in different currencies don't collide.
  def self.cash_for(account, currency: nil)
    distinct = currency.present? && currency.to_s.upcase != account.currency.to_s.upcase
    ticker = (distinct ? "CASH-#{account.id}-#{currency}" : "CASH-#{account.id}").upcase
    find_or_create_by!(ticker: ticker, kind: "cash") do |s|
      s.name = distinct ? "Cash (#{currency.to_s.upcase})" : "Cash"
      s.offline = true
    end
  end

  def cash?
    kind == "cash"
  end

  # Derived rather than stored: developed/emerging is a property of the country,
  # so there is no column for it and nothing to keep in sync. Nil for a country
  # the config does not name.
  def development_status
    return nil if offline?

    REGIONS.dig(country_code.to_s.upcase, "development")
  end

  # `family`'s tags on this security, and no other family's.
  def tags_for(family)
    family.tags.where(id: taggings.select(:tag_id))
  end

  # Moves this security's taggings onto `canonical` when the two are merged.
  # A tag `canonical` already carries stays here and goes with this
  # security's destroy!, as the unique index on taggings allows only one.
  def move_taggings_to!(canonical)
    transaction do
      # The same row lock set_tags_for takes, on both securities in a stable
      # order, so a concurrent tag edit on either waits for the move.
      Security.where(id: [ id, canonical.id ]).order(:id).lock.load

      taggings.where(<<~SQL, canonical.id).update_all(taggable_id: canonical.id)
        NOT EXISTS (
          SELECT 1 FROM taggings carried
          WHERE carried.taggable_type = 'Security'
            AND carried.taggable_id = ?
            AND carried.tag_id = taggings.tag_id
        )
      SQL
      taggings.reset
    end
  end

  # Replaces only `family`'s tags on this security.
  #
  # A wholesale replace would delete other families' taggings on the same
  # instrument, because the row is shared. Ids are resolved through
  # `family.tags` rather than `Tag`, so a tag this family does not own is
  # never attached: that would show its name to every family holding the
  # security.
  #
  # Lock order is security (FOR UPDATE), then tags (FOR SHARE), then taggings.
  # `Tag#replace_and_destroy!` takes taggings then the tag, so the two can
  # deadlock on the same security and tag, and PostgreSQL then aborts one of
  # them with a deadlock error. A new writer should take the locks in this
  # order.
  def set_tags_for(family, tag_ids)
    # `with_lock` reloads the row, which an unsaved security does not have.
    raise ArgumentError, "save the security before tagging it" unless persisted?

    mine = family.tags.select(:id)

    # A check-then-insert on a row every family shares. The unique index on
    # taggings refuses a duplicate, so without the lock two concurrent saves
    # of the same tag would fail one of them rather than both succeed. The
    # lock also reloads the record, so no stale association survives.
    with_lock do
      # Read inside the lock and FOR SHARE: the security's row lock does not
      # cover the tags, so without it a tag deleted between this read and the
      # insert below would fail the insert. A concurrent delete of a wanted
      # tag now waits for this write to commit.
      wanted = family.tags.where(id: Array(tag_ids).reject(&:blank?)).lock("FOR SHARE").pluck(:id)

      taggings.where(tag_id: mine).where.not(tag_id: wanted).destroy_all
      already = taggings.where(tag_id: wanted).pluck(:tag_id)
      (wanted - already).each { |id| taggings.create!(tag_id: id) }
    end
  end

  # True when this security represents a crypto asset. Today the only signal
  # is the Binance ISO MIC — when we add a second crypto provider, extend
  # this check rather than duplicating the test at every call site.
  def crypto?
    exchange_operating_mic == Provider::BinancePublic::BINANCE_MIC
  end

  # Strips the display-currency suffix from a crypto ticker (BTCUSD -> BTC,
  # ETHEUR -> ETH). Returns nil for non-crypto securities or when the ticker
  # doesn't end in a supported quote.
  def crypto_base_asset
    return nil unless crypto?

    # Delegated rather than parsed here: this stripped a fiat suffix only, so it
    # answered nil for the "CRYPTO:BTC" form the holdings processors store — the
    # form every crypto integration writes — and those securities carried no
    # logo at all. The provider already parses every shape it accepts.
    Provider::BinancePublic.parse_ticker(ticker)&.dig(:base)
  end

  # Single source of truth for which logo URL the UI should render.
  # - Crypto keeps its dedicated Brandfetch-crypto shape.
  # - When a website domain is known, Brandfetch (consistent client_id + size)
  #   wins, falling back to any stored logo_url.
  # - With no domain, a stored provider logo (e.g. T-Invest's CDN for MOEX
  #   instruments) is authoritative and beats the ticker-only Brandfetch
  #   lettermark placeholder.
  # A stored Brandfetch logo_url is rewritten to the current size and client
  # id, since holdings and the API render this value without transforming it.
  def display_logo_url
    if crypto?
      self.class.brandfetch_crypto_url(crypto_base_asset).presence || stored_logo_url
    elsif website_url.present?
      brandfetch_icon_url.presence || stored_logo_url
    else
      stored_logo_url || brandfetch_icon_url.presence
    end
  end

  # Returns user-friendly exchange name for a MIC code
  def self.exchange_name_for(mic)
    return nil if mic.blank?
    EXCHANGES.dig(mic.upcase, "name") || mic.upcase
  end

  def self.canonical_exchange_operating_mic(mic)
    return nil if mic.blank?

    key = mic.to_s.upcase
    MIC_ALIASES.fetch(key, key)
  end

  # Values that should match the same venue for DB lookup (canonical + legacy aliases).
  def self.exchange_operating_mic_lookup_values(mic)
    return [] if mic.blank?

    canonical = canonical_exchange_operating_mic(mic)
    aliases = MIC_ALIASES.select { |_legacy, canon| canon == canonical }.keys
    ([ canonical ] + aliases).uniq
  end

  # Finds a security by ticker + MIC, treating legacy MIC aliases as the same
  # venue. When a legacy row is found, upgrades it to the canonical MIC unless
  # a canonical row already exists (in which case the canonical row wins).
  #
  # When +exchange_operating_mic+ is blank:
  # - match_blank_mic: true  → only rows with a blank MIC (find-or-initialize)
  # - match_blank_mic: false → do not filter by MIC (exact DB match by ticker)
  def self.find_by_ticker_and_exchange(ticker:, exchange_operating_mic: nil, country_code: nil, match_blank_mic: false)
    return nil if ticker.blank?

    scope = where("UPPER(ticker) = ?", ticker.to_s.upcase)

    if exchange_operating_mic.present?
      mics = exchange_operating_mic_lookup_values(exchange_operating_mic)
      scope = scope.where("UPPER(exchange_operating_mic) IN (?)", mics)
    elsif match_blank_mic
      scope = scope.where(exchange_operating_mic: [ nil, "" ])
    end

    scope = scope.where(country_code: country_code) if country_code.present?

    canonical = canonical_exchange_operating_mic(exchange_operating_mic)
    security = if canonical.present?
      scope.order(
        Arel.sql(
          sanitize_sql_array([
            "CASE WHEN UPPER(COALESCE(exchange_operating_mic, '')) = ? THEN 0 ELSE 1 END",
            canonical
          ])
        )
      ).first
    else
      scope.first
    end

    return nil unless security
    return security if canonical.blank?
    return security if security.exchange_operating_mic.to_s.upcase == canonical

    existing_canonical = find_by(ticker: security.ticker, exchange_operating_mic: canonical)
    return existing_canonical if existing_canonical

    security.update!(exchange_operating_mic: canonical)
    security
  end

  def self.find_or_initialize_by_ticker_and_exchange(ticker:, exchange_operating_mic: nil)
    existing = find_by_ticker_and_exchange(
      ticker: ticker,
      exchange_operating_mic: exchange_operating_mic,
      match_blank_mic: exchange_operating_mic.blank?
    )
    return existing if existing

    new(
      ticker: ticker,
      exchange_operating_mic: canonical_exchange_operating_mic(exchange_operating_mic)
    )
  end

  def exchange_name
    self.class.exchange_name_for(exchange_operating_mic)
  end

  def current_price
    @current_price ||= find_or_fetch_price
    return nil if @current_price.nil?
    Money.new(@current_price.price, @current_price.currency)
  end

  # Stores user-supplied closes for a security no provider tracks. See Security::ManualPriceImport.
  def import_manual_prices!(rows, accounts:)
    Security::ManualPriceImport.new(security: self, rows: rows, accounts: accounts).import!
  end

  # How many shares one share held at the close of `from` has become by the
  # close of `to`: the product of the ratios of splits whose ex-date falls
  # after `from` and on or before `to`. 1 when there are none.
  def split_factor_between(from, to)
    splits.where(ex_date: (from + 1)..to).reduce(Rational(1)) { |factor, split| factor * split.ratio }
  end

  # The fund expanded into what it actually holds, as fractions of the fund,
  # keyed by [ticker, exchange].
  #
  # A whole-fund list (summing to 99 or more) is normalised against its actual
  # sum, so rounding drift does not under-report every constituent. A partial
  # list is divided by 100 and its fractions sum to less than 1: the rest of the
  # fund is unlisted, not the listed names' to carry. The rule lives in
  # `Security::Constituent.fund_shares`.
  def look_through_weights
    rows = constituents.pluck(:ticker, :exchange, :weight).map { |values| Security::Constituent::Row.new(*values) }
    Security::Constituent.fund_shares(rows).listed
  end

  def to_combobox_option
    ComboboxOption.new(
      symbol: ticker,
      name: name,
      logo_url: logo_url,
      exchange_operating_mic: exchange_operating_mic,
      country_code: country_code,
      price_provider: price_provider,
      currency: search_currency,
      isin: search_isin
    )
  end

  def brandfetch_icon_url(width: nil, height: nil)
    identifier = extract_domain(website_url) if website_url.present?
    identifier ||= ticker

    Setting.brand_fetch_icon_url(identifier, width: width, height: height)
  end

  private

    def stored_logo_url
      Setting.transform_brand_fetch_url(logo_url).presence
    end

    def extract_domain(url)
      uri = URI.parse(url)
      host = uri.host || url
      host.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      nil
    end

    # The weakest writer in the precedence order (default -> provider -> ai ->
    # manual), so it fills only what is still empty and never touches a
    # security whose classification the user has locked. That is what makes it
    # safe on every save, which is also how an existing security picks these
    # up: as it is next written to, with no backfill job.
    #
    # The stronger writers enforce the order, not this code: the provider
    # writer, `Security::Provided#classification_attributes_from`, reads
    # `classification_source` and replaces a `default`, but never `manual` or
    # `ai`.
    def apply_classification_defaults
      return if classification_locked?

      apply_default_asset_class
    end

    # Only the two kinds a provider cannot answer. An ordinary listed
    # instrument is left alone on purpose: "listed in the US" says nothing
    # about whether it is a stock, an ETF or a bond, and guessing would mark
    # it `default` and make the provider's later answer look like an
    # overwrite rather than the first real classification.
    def apply_default_asset_class
      return if asset_class.present? && asset_sub_class.present?

      defaults =
        if cash?
          [ "liquidity", "cash" ]
        elsif crypto?
          [ "alternative_investment", "cryptocurrency" ]
        end
      return if defaults.nil?

      # Each field is filled on its own. Guarding on "either is set" left a
      # half-classified security half-classified for good -- an asset class
      # with no sub-class is not a state anything downstream can group by.
      # But only when the half already there agrees with the default: a cash
      # security another writer called `equity` must not become an
      # `equity`/`cash` pair nobody asserted. That disagreement is left for a
      # stronger writer to settle.
      return unless asset_class.blank? || asset_class == defaults.first
      return unless asset_sub_class.blank? || asset_sub_class == defaults.last

      self.asset_class = defaults.first if asset_class.blank?
      self.asset_sub_class = defaults.last if asset_sub_class.blank?
      # Claimed only when this actually classified the instrument. Filling a
      # region does not make the classification ours.
      self.classification_source ||= "default"
    end

    # Runs once per save, against the values being written. Validation can run
    # several times before a save, and a region derived on an earlier pass
    # would still be pending when the country changed again, then read as the
    # caller's own.
    def apply_default_region
      # An offline security's `country_code` is not the instrument's listing
      # country. `Security::Resolver#offline_security` persists whatever the
      # caller passed, and the resolver's own ranking calls that value
      # `user_country` -- it is a search hint about the person, not a fact
      # about the instrument. Securities are global rather than family-scoped,
      # so deriving a region from it would publish one family's guess to
      # everyone holding that security. Provider-matched securities take
      # `match.country_code`, which is the listing country, and those do
      # classify.
      return if offline?
      # A fund's listing country says nothing about what it holds, so its
      # region comes from the provider's breakdown of its holdings, or not at
      # all. It does not follow a country correction either: a region that
      # equals the old listing's may have come from the holdings, and nothing
      # records which.
      return if asset_sub_class.in?(%w[etf mutual_fund])

      derived = REGIONS.dig(country_code.to_s.upcase, "region")

      if region.blank?
        self.region = derived
      elsif country_code_changed? && !region_changed? && region == REGIONS.dig(country_code_was.to_s.upcase, "region")
        # The country the region was read from has been corrected, and the
        # region still says exactly what the old country implied -- so this
        # callback is what put it there, and it is this callback's to move.
        #
        # There is no column recording who wrote the region, so agreement with
        # the superseded country is what stands in for one. That is the same
        # test `apply_classification_defaults` makes above before touching an
        # asset class it did not assert. A region that disagrees was set by
        # someone who knew something the country does not say -- a
        # cross-listing, a fund domiciled away from what it holds -- and stays.
        #
        # Without this, correcting a country left the two halves of the same
        # fact contradicting each other: `region` frozen on the old country
        # while `development_status`, derived live from `country_code`, had
        # already moved to the new one.
        #
        # A region the caller set in this same save is theirs, not this
        # callback's, so `region_changed?` leaves it alone.
        self.region = derived
      end
    end

    def upcase_symbols
      self.ticker = ticker.upcase
      # Only canonicalize a MIC being written. A stored legacy alias is upgraded by
      # find_by_ticker_and_exchange, which checks for a canonical twin first;
      # rewriting it on an unrelated save would collide with that twin.
      if exchange_operating_mic.present? && will_save_change_to_exchange_operating_mic?
        self.exchange_operating_mic = self.class.canonical_exchange_operating_mic(exchange_operating_mic)
      end
    end

    def should_generate_logo?
      return false if cash?
      return false unless Setting.brand_fetch_client_id.present?

      return true if logo_url.blank?
      return false unless logo_url.include?("cdn.brandfetch.io")

      website_url_changed? || ticker_changed?
    end

    def generate_logo_url_from_brandfetch
      self.logo_url = if crypto?
        self.class.brandfetch_crypto_url(crypto_base_asset)
      else
        brandfetch_icon_url
      end
    end

    # When a user remaps a security to a different provider (via the holdings
    # remap combobox or Security::Resolver), the previously-discovered
    # first_provider_price_on belongs to the OLD provider and may no longer
    # reflect what the new provider can serve. Reset it so the next sync's
    # fallback rediscovers the correct earliest date for the new provider.
    # Skip when the caller explicitly set both columns in the same save.
    def reset_first_provider_price_on_if_provider_changed
      return unless price_provider_changed?
      return if first_provider_price_on_changed?
      self.first_provider_price_on = nil
    end
end
