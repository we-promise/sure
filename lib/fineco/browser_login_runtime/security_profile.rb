# frozen_string_literal: true

require "json"
require "open3"
require "etc"
require "timeout"

module Fineco
  class BrowserLoginRuntime
    class SecurityProfile
      POLICY_PATH = "/etc/chromium/policies/managed/sure-fineco.json".freeze
      CHROMIUM_PATH = "/usr/bin/chromium".freeze
      SUPERVISOR_PATH = "/usr/local/libexec/fineco-browser-supervisor".freeze
      SUPERVISOR_DIR = "/run/sure-fineco".freeze
      RUNTIME_LOCK_PATH = "/tmp/fineco-browser-runtime.lock".freeze
      RAILS_UID = 1000
      RAILS_GID = 1000
      BROWSER_UID = 1001
      BROWSER_GID = 1001
      MAX_POLICY_BYTES = 16 * 1024
      REQUIRED_POLICY = {
        "URLBlocklist" => [ "*", "chrome://*", "chrome-untrusted://*", "devtools://*", "file://*", "chrome-extension://*", "chrome-search://*", "isolated-app://*" ],
        "URLAllowlist" => [ "https://finecobank.com" ],
        "DeveloperToolsAvailability" => 2,
        "DeveloperToolsAvailabilityAllowlist" => [ "finecobank.com" ],
        "DeveloperToolsAvailabilityBlocklist" => [ "*" ],
        "RemoteDebuggingAllowed" => true,
        "AllowFileSelectionDialogs" => false,
        "DownloadRestrictions" => 3,
        "PrintingEnabled" => false,
        "PasswordManagerEnabled" => false,
        "AutofillAddressEnabled" => false,
        "AutofillCreditCardEnabled" => false,
        "BrowserSignin" => 0,
        "SyncDisabled" => true,
        "IncognitoModeAvailability" => 1,
        "ExtensionInstallBlocklist" => [ "*" ]
      }.freeze
      class << self
        def available?
          policy_available? && root_owned_executable?(CHROMIUM_PATH) && supervisor_available? &&
            browser_identity_available? && supported_chromium?
        rescue StandardError
          false
        end

        def secure_directory?(path)
          current = File.expand_path(path)
          loop do
            stat = File.lstat(current)
            return false unless stat.directory? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o022).zero?
            break if current == "/"

            current = File.dirname(current)
          end
          true
        rescue SystemCallError
          false
        end

        def root_owned_file?(path, executable: false)
          stat = File.lstat(path)
          stat.file? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o022).zero? && (!executable || stat.executable?) &&
            secure_directory?(File.dirname(path))
        rescue SystemCallError
          false
        end

        private

          def root_owned_executable?(path)
            root_owned_file?(path, executable: true)
          end

          def supervisor_available?
            return false unless root_owned_file?(SUPERVISOR_PATH, executable: true)

            stat = File.lstat(SUPERVISOR_PATH)
            return false unless stat.gid == RAILS_GID && (stat.mode & 0o7777) == 0o4750

            output, status = Timeout.timeout(2) do
              Open3.capture2(
                { "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
                SUPERVISOR_PATH,
                "--check",
                unsetenv_others: true,
                close_others: true,
                err: File::NULL
              )
            end
            status.success? && output == "FINECO_SUPERVISOR_OK\n"
          rescue SystemCallError, Timeout::Error
            false
          end

          def browser_identity_available?
            rails_user = Etc.getpwuid(RAILS_UID)
            browser_user = Etc.getpwuid(BROWSER_UID)
            browser_group = Etc.getgrgid(BROWSER_GID)
            directory = File.lstat(SUPERVISOR_DIR)
            rails_root = File.lstat("/rails")
            rails_user.gid == RAILS_GID && browser_user.gid == BROWSER_GID &&
              browser_group.name == "fineco-browser" && !Process.groups.include?(BROWSER_GID) &&
              directory.directory? && !directory.symlink? && directory.uid.zero? && directory.gid.zero? &&
              (directory.mode & 0o777) == 0o711 && rails_root.directory? && !rails_root.symlink? &&
              rails_root.uid == RAILS_UID && rails_root.gid == RAILS_GID && (rails_root.mode & 0o777) == 0o750
          rescue ArgumentError, SystemCallError
            false
          end

          def policy_available?
            return false unless root_owned_file?(POLICY_PATH)

            stat = File.lstat(POLICY_PATH)
            return false unless stat.size.positive? && stat.size <= MAX_POLICY_BYTES

            JSON.parse(File.binread(POLICY_PATH)) == REQUIRED_POLICY
          rescue JSON::ParserError, SystemCallError
            false
          end

          def supported_chromium?
            output, status = Timeout.timeout(2) do
              Open3.capture2(
                { "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
                CHROMIUM_PATH,
                "--version",
                unsetenv_others: true,
                close_others: true,
                err: File::NULL
              )
            end
            return false unless status.success?

            match = output.match(/\AChromium (\d+)\./)
            match && match[1].to_i >= 147
          rescue SystemCallError, Timeout::Error
            false
          end
      end
    end
  end
end
