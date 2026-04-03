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
      env.keys.grep(/_FILE\z/).sort.each do |file_key|
        base_key = file_key.delete_suffix("_FILE")
        next if denylisted?(base_key, file_key, warn_io)
        next if env[base_key].to_s != ""

        path = env[file_key].to_s.strip
        next if path.empty?

        content = read(path, file_key: file_key, base_key: base_key, warn_io: warn_io)
        env[base_key] = content unless content.nil?
      end
    end

    def read(path, file_key:, base_key:, warn_io: $stderr)
      File.read(path).chomp
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      warn_io.puts("[env] Unable to load #{file_key} for #{base_key} from #{path}: #{e.message}")
      nil
    end

    def denylisted?(base_key, file_key, warn_io)
      return false unless DENYLIST.include?(base_key)

      warn_io.puts("[env] Ignoring #{file_key}: #{base_key} is not eligible for *_FILE loading")
      true
    end
  end
end
