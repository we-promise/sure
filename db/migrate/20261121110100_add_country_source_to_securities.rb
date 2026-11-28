# Records where a security's `country_code` came from, so a country that is
# only a family's search hint never drives `region` or `development_status`.
# NULL is a country from a writer that does not say, trusted as before.
class AddCountrySourceToSecurities < ActiveRecord::Migration[8.1]
  CONSTRAINT = "chk_securities_country_source"
  SOURCES = %w[user_hint provider].freeze

  def up
    add_column :securities, :country_source, :string
    quoted = SOURCES.map { |source| connection.quote(source) }.join(", ")
    add_check_constraint :securities, "country_source IN (#{quoted})", name: CONSTRAINT

    mark_fallback_hints
  end

  def down
    remove_check_constraint :securities, name: CONSTRAINT
    remove_column :securities, :country_source
  end

  private
    # `Security::Resolver#offline_security` writes the family's country on an
    # offline row with no reason or "resolution_pending". Other importers'
    # fallbacks can also leave a provider row offline with no reason, so only a
    # country the exchange does not confirm is marked; `Security#country_hint?`
    # decides, as it does at read time. Residual: such a fallback row with no
    # exchange, or one that disagrees, is marked too, and gets no region when
    # it next comes online until a provider match or a corrected country.
    # Offline rows hold no derived region, so none is cleared. Online rows that
    # derived a region from a hint before this column existed cannot be told
    # from provider rows, and are left as they are.
    def mark_fallback_hints
      Security.reset_column_information
      rows = select_rows(<<~SQL)
        SELECT id, country_code, exchange_operating_mic FROM securities
        WHERE offline AND country_code IS NOT NULL AND country_code <> ''
          AND (offline_reason IS NULL OR offline_reason = 'resolution_pending')
      SQL
      ids = rows.filter_map do |id, country, mic|
        id if Security.new(country_code: country, exchange_operating_mic: mic, country_source: "user_hint").country_hint?
      end

      ids.each_slice(1000) do |batch|
        execute("UPDATE securities SET country_source = 'user_hint' WHERE id IN (#{batch.map { |id| connection.quote(id) }.join(', ')})")
      end
    end
end
