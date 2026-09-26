require "test_helper"

# Defaults for the classification a provider cannot supply. A provider returns
# nothing useful for a synthetic cash security or a crypto pair, and `region`
# has no provider field at all -- it is derived from the country the instrument
# is listed in.
#
# Every assertion here is about a write that must NOT happen as much as one
# that must: these defaults are the weakest source in the precedence order
# (default -> provider -> ai -> manual, with `classification_locked` vetoing
# all of them), so the interesting cases are the ones where something better
# is already present.
class Security::ClassificationDefaultsTest < ActiveSupport::TestCase
  # -------------------------------------------------------------- asset class

  test "a cash security classifies as liquidity and cash" do
    security = Security.create!(ticker: "CASH-DEFAULTS-1", kind: "cash", offline: true)

    assert_equal "liquidity", security.asset_class
    assert_equal "cash", security.asset_sub_class
    assert_equal "default", security.classification_source
  end

  test "a crypto security classifies as alternative investment and cryptocurrency" do
    security = Security.create!(
      ticker: "BTCUSD-DEFAULTS",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC
    )

    assert_predicate security, :crypto?
    assert_equal "alternative_investment", security.asset_class
    assert_equal "cryptocurrency", security.asset_sub_class
    assert_equal "default", security.classification_source
  end

  # Declared after `:upcase_symbols` on purpose, because `crypto?` compares
  # against a canonical MIC. The test above cannot prove that ordering -- it
  # passes the already-canonical "BNCX", which survives either order. This one
  # passes a lowercase MIC, so it only classifies if the canonicalising
  # callback has already run.
  test "a crypto security given a lowercase MIC is still classified" do
    security = Security.create!(
      ticker: "ETHUSD-DEFAULTS",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC.downcase
    )

    assert_equal "alternative_investment", security.asset_class,
                 "the defaults ran before the MIC was canonicalised, so crypto? did not see it"
    assert_equal "cryptocurrency", security.asset_sub_class
  end

  # An ordinary listed equity is exactly what these defaults must NOT guess at:
  # "US-listed" does not mean "stock", and the provider slice is what answers
  # this. Getting it wrong here would mark thousands of securities `default`
  # and make 3.1's provider write look like an overwrite.
  test "an ordinary security is left unclassified for a provider to answer" do
    security = Security.create!(ticker: "ORD-DEFAULTS", exchange_operating_mic: "XNAS", country_code: "US")

    assert_nil security.asset_class
    assert_nil security.asset_sub_class
    assert_nil security.classification_source, "asset class was not defaulted, so nothing set the source"
  end

  # ------------------------------------------------------------------- region

  test "region is derived from the country the security is listed in" do
    security = Security.create!(ticker: "REG-US", country_code: "US")

    assert_equal "north_america", security.region
  end

  test "an unknown country code leaves region nil rather than guessing" do
    security = Security.create!(ticker: "REG-ZZ", country_code: "ZZ")

    assert_nil security.region
  end

  test "a blank country code leaves region nil" do
    security = Security.create!(ticker: "REG-NONE", country_code: nil)

    assert_nil security.region
  end

  # `region` is filled even when a provider already answered the asset class,
  # because no provider supplies region -- so the two must not be gated on each
  # other. The source stays `provider`: this did not classify the instrument,
  # it only located it.
  test "region is filled alongside a provider classification without claiming it" do
    security = Security.create!(
      ticker: "REG-PROV",
      country_code: "JP",
      asset_class: "equity",
      asset_sub_class: "stock",
      classification_source: "provider"
    )

    assert_equal "asia_pacific", security.region
    assert_equal "provider", security.classification_source, "filling region must not restate the source"
  end

  # The country lookup must not relitigate a region that is already there. A
  # security can be listed in one country and be a claim on another -- an ADR,
  # a cross-listing, a fund domiciled away from what it holds -- so a region
  # someone set deliberately outranks the one the listing implies.
  test "a region already set is not replaced by the country lookup" do
    security = Security.create!(ticker: "REG-KEEP", country_code: "US", region: "asia_pacific")

    assert_equal "asia_pacific", security.region, "the country lookup overwrote a region already set"
  end

  # An offline security's country_code is a search hint about the PERSON, not a
  # fact about the instrument: `Security::Resolver#offline_security` persists
  # whatever the caller passed, and the resolver's own ranking calls that value
  # `user_country`. Securities are global, so deriving a region from it would
  # publish one family's guess to everyone else holding the same ticker.
  test "an offline security gets no region, because its country code is the user's" do
    security = Security.create!(ticker: "REG-OFFLINE", country_code: "US", offline: true)

    assert_nil security.region, "a user's own country was published as the instrument's region"
    assert_nil security.development_status
  end

  # Named for what it verifies, not for a path it never takes. There is no
  # provider match and no Security::Resolver here -- a plain create with
  # `offline: false` exercises the `offline?` guard in `apply_default_region`
  # and nothing more, and the old name implied coverage that does not exist
  # (raised by cubic on #201).
  test "an online security gets a region from its country" do
    security = Security.create!(ticker: "REG-ONLINE", country_code: "US", offline: false)

    assert_equal "north_america", security.region
    assert_equal "developed", security.development_status
  end

  # ------------------------------------------------- precedence and the lock

  test "a manual classification is never overwritten by a default" do
    security = Security.create!(
      ticker: "CASH-MANUAL",
      kind: "cash",
      offline: true,
      asset_class: "equity",
      asset_sub_class: "stock",
      classification_source: "manual"
    )

    assert_equal "equity", security.asset_class, "a default overwrote a value a user asserted"
    assert_equal "stock", security.asset_sub_class
    assert_equal "manual", security.classification_source
  end

  # The lock is the user's veto over every source, including this one, and it
  # holds even when there is nothing to protect yet: a locked security with no
  # classification is a user saying "leave this alone", not an empty slot.
  test "a locked security is not classified at all" do
    security = Security.create!(ticker: "CASH-LOCKED", kind: "cash", offline: true, classification_locked: true)

    assert_nil security.asset_class
    assert_nil security.asset_sub_class
    assert_nil security.classification_source
  end

  test "a locked security does not get a region either" do
    security = Security.create!(ticker: "REG-LOCKED", country_code: "US", classification_locked: true)

    assert_nil security.region
  end

  # `classification_source` is what the precedence order is read from, so this
  # default may fill an empty asset class without relabelling a source someone
  # else set. Restating it as `default` would demote a user's marker and make
  # a later provider write look permitted when it is not.
  test "filling an empty asset class does not relabel a source already set" do
    security = Security.create!(
      ticker: "CASH-SRCSET",
      kind: "cash",
      offline: true,
      classification_source: "manual"
    )

    assert_equal "liquidity", security.asset_class, "the empty asset class should still have been filled"
    assert_equal "manual", security.classification_source, "the default relabelled a source it did not set"
  end

  # ------------------------------------------------------------- idempotence

  # The callback runs on every save, so it has to be a no-op once it has
  # answered. If it were not, a later save would restate `default` over a
  # provider value that arrived in between.
  test "a later save does not restate a default over a provider classification" do
    security = Security.create!(ticker: "CASH-LATER", kind: "cash", offline: true)
    assert_equal "default", security.classification_source

    security.update!(asset_class: "equity", asset_sub_class: "stock", classification_source: "provider")
    security.update!(name: "touched again")

    assert_equal "equity", security.reload.asset_class
    assert_equal "provider", security.classification_source
  end

  # ---------------------------------------------------------- the config file

  test "every region in the config is one of the five the taxonomy names" do
    regions = Security::REGIONS.values.map { |entry| entry["region"] }.uniq

    assert_equal Security::REGION_KEYS.sort, regions.sort
  end

  # The test that would have caught Norway. `NO` is a YAML 1.1 boolean literal,
  # so an unquoted `NO:` key loads as `false`, the lookup by string misses it,
  # and every Norwegian security is silently left with no region. The
  # region-values test above cannot see it: the offending entry's VALUE is
  # perfectly valid, it is the KEY that is the wrong type.
  test "every country code is a two-letter string, not something YAML read as a value" do
    non_strings = Security::REGIONS.keys.reject { |key| key.is_a?(String) }
    assert_empty non_strings,
                 "YAML read these keys as values rather than country codes; quote them: #{non_strings.inspect}"

    Security::REGIONS.each_key do |code|
      assert_match(/\A[A-Z]{2}\z/, code, "#{code.inspect} is not an ISO 3166-1 alpha-2 code")
    end
  end

  test "Norway resolves, since its code is one YAML would otherwise read as false" do
    assert_equal "europe", Security::REGIONS.dig("NO", "region")
    assert_equal "europe", Security.create!(ticker: "REG-NO", country_code: "NO").region
  end

  # `region` has no database constraint, so the model validation is the only
  # thing standing between REGION_KEYS and an allocation chart with a sixth
  # slice in it.
  test "a region outside the vocabulary is refused" do
    security = securities(:aapl)

    security.region = "atlantis"
    assert_not security.valid?
    assert_includes security.errors[:region], "is not included in the list"

    security.region = nil
    assert security.valid?, "nil is the honest answer for a country the config does not name"
  end

  # A security carrying one half of a classification and not the other is not
  # "already classified" -- it is half-filled, and the missing half is exactly
  # what this is for.
  test "a half-filled classification has its missing half filled" do
    security = Security.create!(ticker: "CASH-HALF", kind: "cash", offline: true,
                                asset_class: "liquidity", classification_source: "manual")

    assert_equal "cash", security.asset_sub_class, "the missing sub-class was left empty"
    assert_equal "liquidity", security.asset_class, "the half that was set moved"
    assert_equal "manual", security.classification_source
  end

  test "every country in the config declares a development classification" do
    Security::REGIONS.each do |code, entry|
      assert_includes %w[developed emerging], entry["development"],
                      "#{code} has an unusable development value"
    end
  end

  test "development status is derived rather than stored" do
    security = Security.create!(ticker: "DEV-US", country_code: "US")

    assert_equal "developed", security.development_status
    assert_nil Security.create!(ticker: "DEV-ZZ", country_code: "ZZ").development_status
  end
end
