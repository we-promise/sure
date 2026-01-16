# frozen_string_literal: true

# DatabaseMirrorService - Handles mirroring operations to external PostgreSQL
#
# This service manages the connection to the external mirror database and
# performs CRUD operations. It uses a separate connection pool to avoid
# impacting the primary database operations.
#
# Key features:
# - Separate connection pool for mirror database
# - Schema detection: only initializes if database is empty
# - Thread-safe connection handling
#
class DatabaseMirrorService
  class MirrorConnectionError < StandardError; end
  class SchemaNotInitializedError < StandardError; end

  # Abstract base class for mirror database connection
  class MirrorRecord < ActiveRecord::Base
    self.abstract_class = true

    class << self
      def establish_mirror_connection
        return if @mirror_connected

        config = mirror_connection_config
        Rails.logger.info("[MirrorRecord] Connecting to #{config[:host]}:#{config[:port]}/#{config[:database]}")

        establish_connection(config)

        # Verify connection actually works
        connection.execute("SELECT 1")
        @mirror_connected = true
        Rails.logger.info("[MirrorRecord] Successfully connected to mirror database")
      rescue => e
        @mirror_connected = false
        Rails.logger.error("[MirrorRecord] Connection failed: #{e.class} - #{e.message}")
        raise
      end

      def mirror_connected?
        @mirror_connected == true
      end

      def mirror_connection_config
        {
          adapter: "postgresql",
          host: ENV.fetch("MIRROR_DB_HOST", nil),
          port: ENV.fetch("MIRROR_DB_PORT", "5432"),
          database: ENV.fetch("MIRROR_DB_NAME", nil),
          username: ENV.fetch("MIRROR_DB_USER", nil),
          password: ENV.fetch("MIRROR_DB_PASSWORD", nil),
          sslmode: ENV.fetch("MIRROR_DB_SSLMODE", "prefer"),
          pool: ENV.fetch("MIRROR_DB_POOL", "3").to_i,
          connect_timeout: 15
        }
      end
    end
  end

  def initialize
    @schema_initialized = false
  end

  # Mirror a create operation
  def mirror_create(model_class, primary_key, attributes)
    ensure_connection!
    ensure_schema_initialized!

    table_name = model_class.constantize.table_name
    columns = attributes.keys
    values = attributes.values

    sql = <<~SQL
      INSERT INTO #{connection.quote_table_name(table_name)}
      (#{columns.map { |c| connection.quote_column_name(c) }.join(", ")})
      VALUES (#{values.map { |v| quote_value(v) }.join(", ")})
      ON CONFLICT (#{connection.quote_column_name(primary_key_column(model_class))})
      DO UPDATE SET #{columns.map { |c| "#{connection.quote_column_name(c)} = EXCLUDED.#{connection.quote_column_name(c)}" }.join(", ")}
    SQL

    connection.execute(sql)
    Rails.logger.info("[DatabaseMirrorService] Created #{model_class}##{primary_key} in mirror")
  rescue => e
    Rails.logger.error("[DatabaseMirrorService] Failed to create #{model_class}##{primary_key}: #{e.message}")
    raise
  end

  # Mirror an update operation
  def mirror_update(model_class, primary_key, attributes)
    ensure_connection!
    ensure_schema_initialized!

    table_name = model_class.constantize.table_name
    pk_column = primary_key_column(model_class)
    pk_value = attributes[pk_column] || primary_key

    set_clause = attributes.except(pk_column).map do |col, val|
      "#{connection.quote_column_name(col)} = #{quote_value(val)}"
    end.join(", ")

    return if set_clause.blank?

    sql = <<~SQL
      UPDATE #{connection.quote_table_name(table_name)}
      SET #{set_clause}
      WHERE #{connection.quote_column_name(pk_column)} = #{connection.quote(pk_value)}
    SQL

    connection.execute(sql)
    Rails.logger.info("[DatabaseMirrorService] Updated #{model_class}##{primary_key} in mirror")
  rescue => e
    Rails.logger.error("[DatabaseMirrorService] Failed to update #{model_class}##{primary_key}: #{e.message}")
    raise
  end

  # Mirror a destroy operation
  def mirror_destroy(model_class, primary_key)
    ensure_connection!
    ensure_schema_initialized!

    table_name = model_class.constantize.table_name
    pk_column = primary_key_column(model_class)

    sql = <<~SQL
      DELETE FROM #{connection.quote_table_name(table_name)}
      WHERE #{connection.quote_column_name(pk_column)} = #{connection.quote(primary_key)}
    SQL

    connection.execute(sql)
    Rails.logger.info("[DatabaseMirrorService] Destroyed #{model_class}##{primary_key} from mirror")
  rescue => e
    Rails.logger.error("[DatabaseMirrorService] Failed to destroy #{model_class}##{primary_key}: #{e.message}")
    raise
  end

  # Check if the mirror database has any tables (is empty)
  def database_empty?
    ensure_connection!

    result = connection.execute(<<~SQL)
      SELECT COUNT(*) as count
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
    SQL

    result.first["count"].to_i == 0
  end

  # Initialize schema in the mirror database if it's empty
  def initialize_schema_if_empty!
    return unless database_empty?

    Rails.logger.info("[DatabaseMirrorService] Mirror database is empty, initializing schema...")

    # Load the schema from the primary database
    schema_sql = File.read(Rails.root.join("db", "structure.sql"))
  rescue Errno::ENOENT
    # Fall back to schema.rb if structure.sql doesn't exist
    Rails.logger.info("[DatabaseMirrorService] structure.sql not found, using schema dump...")
    initialize_schema_from_schema_rb!
  else
    connection.execute(schema_sql)
    Rails.logger.info("[DatabaseMirrorService] Schema initialized in mirror database")
  end

  private

    def connection
      MirrorRecord.connection
    end

    def ensure_connection!
      MirrorRecord.establish_mirror_connection

      unless MirrorRecord.mirror_connected?
        raise MirrorConnectionError, "Failed to establish connection to mirror database"
      end
    end

    def ensure_schema_initialized!
      return if @schema_initialized

      if database_empty?
        initialize_schema_if_empty!
      end

      @schema_initialized = true
    end

    def primary_key_column(model_class)
      model_class.constantize.primary_key || "id"
    end

    # Quote a value for SQL, handling special cases:
    # - JSON-serialized arrays ("[]") -> PostgreSQL array format ('{}')
    # - JSON-serialized hashes -> JSONB cast
    # - Regular values -> standard quoting
    def quote_value(value)
      case value
      when nil
        "NULL"
      when true
        "TRUE"
      when false
        "FALSE"
      when String
        # Check if it's a JSON array serialized as string
        if value.start_with?("[") && value.end_with?("]")
          # Convert JSON array to PostgreSQL array format
          begin
            parsed = JSON.parse(value)
            if parsed.is_a?(Array)
              pg_array = parsed.map { |v| connection.quote(v) }.join(", ")
              "ARRAY[#{pg_array}]::text[]"
            else
              connection.quote(value)
            end
          rescue JSON::ParserError
            connection.quote(value)
          end
        elsif value.start_with?("{") && value.end_with?("}")
          # JSON object - use JSONB cast
          "#{connection.quote(value)}::jsonb"
        else
          connection.quote(value)
        end
      when Integer, Float
        value.to_s
      else
        connection.quote(value)
      end
    end

    def initialize_schema_from_schema_rb!
      # Read the current schema and apply it to the mirror database
      schema_content = File.read(Rails.root.join("db", "schema.rb"))

      # Extract and execute table creation statements
      # This is a simplified approach - for complex schemas, consider using
      # ActiveRecord::Schema.define with the mirror connection
      ActiveRecord::Base.connection_pool.with_connection do
        tables = ActiveRecord::Base.connection.tables

        tables.each do |table_name|
          next if table_name == "schema_migrations" || table_name == "ar_internal_metadata"

          columns_sql = generate_create_table_sql(table_name)
          connection.execute(columns_sql) if columns_sql.present?
        end
      end

      Rails.logger.info("[DatabaseMirrorService] Schema initialized from schema.rb")
    end

    def generate_create_table_sql(table_name)
      primary_connection = ActiveRecord::Base.connection

      columns = primary_connection.columns(table_name)
      primary_key = primary_connection.primary_key(table_name)

      column_definitions = columns.map do |col|
        sql_type = col.sql_type
        null_constraint = col.null ? "" : " NOT NULL"
        default = col.default.nil? ? "" : " DEFAULT #{connection.quote(col.default)}"

        "#{connection.quote_column_name(col.name)} #{sql_type}#{null_constraint}#{default}"
      end

      pk_constraint = primary_key ? ", PRIMARY KEY (#{connection.quote_column_name(primary_key)})" : ""

      <<~SQL
        CREATE TABLE IF NOT EXISTS #{connection.quote_table_name(table_name)} (
          #{column_definitions.join(",\n  ")}#{pk_constraint}
        )
      SQL
    rescue => e
      Rails.logger.error("[DatabaseMirrorService] Failed to generate CREATE TABLE for #{table_name}: #{e.message}")
      nil
    end
end
