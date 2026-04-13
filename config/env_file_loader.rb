# frozen_string_literal: true

module Sure
  module EnvFileLoader
    module_function

    DENYLIST = %w[
      BUNDLE_GEMFILE
      PIDFILE
      SSL_CA_FILE
      SSL_CERT_FILE
    ].freeze

    def load!(env: ENV, warn_io: $stderr)
      env.keys.grep(/_FILE\z/).reject { |file_key| DENYLIST.include?(file_key) }.sort.each do |file_key|
        base_key = file_key.delete_suffix("_FILE")
        next if DENYLIST.include?(base_key)
        next if env.key?(base_key)

        path = env[file_key].to_s.strip
        next if path.empty?

        content = read(path, file_key: file_key, base_key: base_key, warn_io: warn_io)
        env[base_key] = content unless content.nil?
      end
    end

    def read(path, file_key:, base_key:, warn_io: $stderr)
      File.read(path).chomp
    rescue SystemCallError => e
      warn_io.puts("[env] Unable to load #{file_key} for #{base_key} from #{path}: #{e.message}")
      nil
    end
  end
end
