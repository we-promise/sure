# frozen_string_literal: true

# Schema for classifying a security by asset class, sub-class, sector, industry
# and region, with provenance and a lock so a user's manual classification is
# not overwritten by a provider or a default.
#
# Schema only. Nothing reads or writes the columns until a later drop, so
# every value stays NULL and the migration carries no data risk.
#
# The enumerated columns are plain strings with a check constraint, matching
# `securities.kind` (`chk_securities_kind`) and `loans.day_count_convention`:
# adding a value later is a constraint swap, not a type change. The permitted
# values are the six-class / twelve-sub-class taxonomy other portfolio trackers
# use, so an import maps onto them without a translation table.
#
# Written as explicit up/down rather than `change` because the constraints are
# added NOT VALID and validated afterwards. On PostgreSQL that is two short
# locks instead of one full-table scan under an exclusive lock; it needs
# `disable_ddl_transaction!` to mean anything, and `validate_check_constraint`
# has no inverse for a `change` block to record.
class AddClassificationToSecurities < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # These lists are deliberately repeated here rather than read from
  # `Security::ASSET_CLASSES` and friends. A migration has to produce the same
  # schema whenever it is run -- on a fresh install today, on a self-hosted
  # instance upgrading in a year -- and a constant it borrowed from a model
  # would produce a different constraint once the model's list changed. That is
  # the usual reason migrations do not reference application code, and it
  # applies here rather than being a copy-paste.
  #
  # The cost is that growing the taxonomy is a two-file edit. `SecurityTest`
  # "the model taxonomy and the database constraint list the same values" reads
  # the rendered constraint back out of the catalog and compares it to the
  # model's constants, so the two cannot silently diverge -- a change to one
  # without the other fails that test rather than shipping.

  ASSET_CLASSES = %w[
    alternative_investment commodity equity fixed_income liquidity real_estate
  ].freeze

  ASSET_SUB_CLASSES = %w[
    bond cash collectible commodity cryptocurrency etf loan mutual_fund
    precious_metal private_equity real_estate stock
  ].freeze

  CLASSIFICATION_SOURCES = %w[provider manual ai default].freeze

  CONSTRAINTS = {
    "chk_securities_asset_class" => [ "asset_class", ASSET_CLASSES ],
    "chk_securities_asset_sub_class" => [ "asset_sub_class", ASSET_SUB_CLASSES ],
    "chk_securities_classification_source" => [ "classification_source", CLASSIFICATION_SOURCES ]
  }.freeze

  # Every step is written to be safe to run again. Without a DDL transaction
  # each statement commits on its own while schema_migrations stays unwritten,
  # so a process killed part-way leaves some columns created and the migration
  # still pending -- and the next run would die on "column already exists"
  # rather than finishing the job.
  def up
    add_column :securities, :asset_class, :string, if_not_exists: true
    add_column :securities, :asset_sub_class, :string, if_not_exists: true
    # Free text, and deliberately so: these come from providers, each with its
    # own vocabulary (EODHD's `General.Sector` is not GICS, and no two agree on
    # region). There is no constraint and no `inclusion` validation on purpose
    # -- adding one would reject a value a provider legitimately returns and
    # break classification ingestion for that provider. Normalisation, if it
    # ever happens, belongs above these columns rather than in them.
    add_column :securities, :sector, :string, if_not_exists: true
    add_column :securities, :industry, :string, if_not_exists: true
    add_column :securities, :region, :string, if_not_exists: true
    add_column :securities, :classification_source, :string, if_not_exists: true
    # A boolean with a constant default is a catalog-only change on
    # PostgreSQL 11+; existing rows are not rewritten. The project ships
    # PostgreSQL 16 (compose.example.yml, .devcontainer) and the existing
    # loans migrations rely on the same behaviour.
    #
    # `null: false` means an explicit nil write raises rather than falling back
    # to the default -- `update_column(:classification_locked, nil)` and any
    # other ORM bypass included. That is intended: "locked" is a yes or no, and
    # a third state would leave a later writer guessing whether it may replace
    # a user's classification.
    add_column :securities, :classification_locked, :boolean, null: false, default: false, if_not_exists: true

    CONSTRAINTS.each do |name, (column, values)|
      add_check_constraint :securities, "#{column} IN (#{values.map { |v| "'#{v}'" }.join(', ')})",
        name: name, validate: false, if_not_exists: true
    end

    CONSTRAINTS.each_key do |name|
      validate_check_constraint :securities, name: name
    end
  end

  def down
    CONSTRAINTS.each_key do |name|
      remove_check_constraint :securities, name: name, if_exists: true
    end

    %i[
      classification_locked classification_source region industry sector
      asset_sub_class asset_class
    ].each { |column| remove_column :securities, column, if_exists: true }
  end
end
