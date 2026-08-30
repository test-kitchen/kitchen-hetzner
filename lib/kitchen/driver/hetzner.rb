#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "securerandom" unless defined?(SecureRandom)
require "time" unless defined?(Time)
require "yaml" unless defined?(YAML)

require "kitchen"
require "kitchen/driver/base"

require_relative "hetzner_version"
require_relative "hcloud/api_error"
require_relative "hcloud/client"
require_relative "hcloud/image_map"
require_relative "hcloud/ssh_key"

module Kitchen
  # Test Kitchen's driver plugins.
  module Driver
    # A Test Kitchen driver that runs instances on Hetzner Cloud.
    #
    # The driver creates a server, injects an SSH key, waits for the server to
    # become reachable, and tears it all down again on `kitchen destroy`. Any
    # provisioner works; the Cinc-focused examples in the README are a
    # documentation choice, not a coupling.
    #
    # @example Minimal kitchen.yml
    #   driver:
    #     name: hetzner
    #
    #   provisioner:
    #     name: cinc_infra
    #
    #   platforms:
    #     - name: ubuntu-24.04
    class Hetzner < Kitchen::Driver::Base
      kitchen_driver_api_version 2

      plugin_version Kitchen::Driver::HETZNER_VERSION

      # @return [String] server type used when none is configured
      DEFAULT_SERVER_TYPE = "cx22".freeze

      # @return [String] location used when none is configured
      DEFAULT_LOCATION = "fsn1".freeze

      # @return [String] label value marking servers this driver created
      CREATED_BY = "test-kitchen".freeze

      # @return [Integer] maximum length of a Hetzner server name
      MAX_NAME_LENGTH = 63

      default_config :server_type, DEFAULT_SERVER_TYPE
      default_config :location, DEFAULT_LOCATION
      default_config :username, "root"
      default_config :port, 22
      default_config :user_data, nil
      default_config :ssh_keys, nil
      default_config :server_name, nil
      default_config :labels, {}
      default_config :api_url, Hcloud::Client::API_ROOT
      default_config :server_ready_timeout, Hcloud::Client::ACTION_TIMEOUT

      default_config :hetzner_token do
        ENV["HCLOUD_TOKEN"] || ENV["HETZNER_TOKEN"]
      end

      default_config(:image, &:default_image)

      required_config :hetzner_token do |_attr, value, _driver|
        if value.nil? || value.to_s.empty?
          raise UserError, "A Hetzner Cloud API token is required. Set the " \
                           "HCLOUD_TOKEN environment variable, or the " \
                           "hetzner_token driver option in your kitchen.yml."
        end
      end

      # Creates the Hetzner server and waits until it accepts SSH.
      #
      # Safe to call repeatedly: if state already records a server, this is a
      # no-op, which is what Test Kitchen relies on when re-running `create`.
      #
      # If any step fails after resources exist, they are torn down before the
      # error propagates so that a failed create does not leak a running server.
      #
      # @param state [Hash] mutable instance state
      # @return [void]
      # @raise [Kitchen::ActionFailed] if the server could not be created
      def create(state)
        return if state[:server_id]

        validate_platform!

        begin
          ssh_key_ids = provision_ssh_key(state)
          provision_server(state, ssh_key_ids)
          await_ssh(state)
        rescue ::StandardError => e
          # Deliberately every error, not a hand-picked list. By this point a
          # server may already be running and billing, and the most likely
          # failure is the last step: `wait_until_ready` raises
          # Kitchen::Transport::TransportFailed, which is a sibling of
          # ActionFailed rather than a subclass, so naming the expected classes
          # is exactly how a server gets left behind.
          cleanup_after_failed_create(state)
          raise Kitchen::ActionFailed, error_summary(e)
        end
      end

      # Destroys the Hetzner server and any SSH key this driver created.
      #
      # Tolerates missing or partially written state, because Test Kitchen runs
      # `destroy` against whatever the state file happens to contain after a
      # cancelled or crashed run.
      #
      # @param state [Hash] mutable instance state
      # @return [void]
      # @raise [Kitchen::ActionFailed] if the API rejects the deletion
      def destroy(state)
        if state[:server_id]
          info("Destroying Hetzner server <#{state[:server_id]}>...")
          deleted = with_api_errors { client.delete_server(state[:server_id]) }
          info(deleted ? "Hetzner server <#{state[:server_id]}> destroyed." : "Hetzner server <#{state[:server_id]}> was already gone.")
        end

        destroy_ephemeral_key(state)

        state.delete(:server_id)
        state.delete(:server_name)
        state.delete(:hostname)
      end

      # Reports whether the backing server is live.
      #
      # @param state [Hash] mutable instance state
      # @return [Hash] normalized status data for `kitchen status`
      def status(state)
        return unknown_status("no server recorded in state") unless state[:server_id]

        server = with_api_errors { client.server(state[:server_id]) }
        return unknown_status("server <#{state[:server_id]}> no longer exists", live: false, state: "destroyed") if server.nil?

        {
          live: server["status"] == "running",
          state: server["status"],
          source: "driver",
          resource_id: server["id"],
          message: "Hetzner server #{server["name"]} is #{server["status"]}",
          checked_at: Time.now.utc.iso8601,
        }
      end

      # Reports servers this driver created that no local state file knows about.
      #
      # A cancelled CI job leaves servers running with no state to destroy them.
      # Because every server is labelled `created_by=test-kitchen`, they can be
      # listed and compared against the state files on disk. This only reports;
      # it never deletes, since a Hetzner project may be shared with other work.
      #
      # @param state [Hash] mutable instance state
      # @return [Boolean] true if orphaned servers were found
      def doctor(state)
        servers = with_api_errors { client.servers(label_selector: "created_by=#{CREATED_BY}") }
        known = known_server_ids(state)
        orphans = servers.reject { |s| known.include?(s["id"]) }

        return false if orphans.empty?

        report_orphans(orphans)
        true
      end

      # Resolves the image slug for the instance's platform.
      #
      # Used as the default for the `image` config option.
      #
      # @return [String, nil] a Hetzner image slug
      def default_image
        Hcloud::ImageMap.image_for(instance.platform.name)
      end

      private

      # Builds the API client, memoized per driver instance.
      #
      # @return [Hcloud::Client] the configured client
      def client
        @client ||= Hcloud::Client.new(
          token: config[:hetzner_token],
          logger: logger,
          api_root: config[:api_url]
        )
      end

      # Rejects platforms Hetzner Cloud cannot boot.
      #
      # @return [void]
      # @raise [Kitchen::ActionFailed] for an unsupported platform family
      def validate_platform!
        return unless Hcloud::ImageMap.unsupported?(instance.platform.name)

        raise Kitchen::ActionFailed,
          "Hetzner Cloud does not offer #{instance.platform.name} images, so " \
          "this platform cannot be tested with kitchen-hetzner. Use a Linux " \
          "platform, or a driver that supports Windows such as kitchen-ec2."
      end

      # Ensures an SSH key exists for the instance.
      #
      # When the user has named their own keys nothing is created or deleted.
      # Otherwise a throwaway keypair is generated, uploaded, and recorded in
      # state so that {#destroy} can remove it later.
      #
      # @param state [Hash] mutable instance state
      # @return [Array<String, Integer>] SSH key names or IDs to inject
      def provision_ssh_key(state)
        configured = Array(config[:ssh_keys]).compact
        return configured unless configured.empty?

        key = Hcloud::SshKey.generate
        name = unique_name("kitchen")
        path = ephemeral_key_path

        debug("Generating an ephemeral SSH keypair at #{path}")
        key.write(path)

        # Recorded before the upload, not after: if the upload fails, the
        # private key is already on disk and only state can lead cleanup to it.
        # :hetzner_ssh_key_path is this driver's own key, so cleanup can tell a
        # file it wrote from a :ssh_key that came from somewhere else.
        state[:hetzner_ssh_key_path] = path
        state[:ssh_key] = path

        created = with_api_errors do
          client.create_ssh_key(
            name: name,
            public_key: key.openssh_public_key(comment: name),
            labels: base_labels
          )
        end

        state[:hetzner_ssh_key_id] = created["id"]

        [created["id"]]
      end

      # Creates the server and records connection details in state.
      #
      # @param state [Hash] mutable instance state
      # @param ssh_key_ids [Array<String, Integer>] keys to inject
      # @return [void]
      def provision_server(state, ssh_key_ids)
        name = config[:server_name] || unique_name(instance.name)

        info("Creating Hetzner server #{name} (#{config[:server_type]}, #{config[:image]}, #{config[:location]})...")

        response = with_api_errors do
          client.create_server(
            name: name,
            server_type: config[:server_type],
            image: config[:image],
            location: config[:location],
            ssh_keys: ssh_key_ids,
            user_data: config[:user_data],
            labels: server_labels
          )
        end

        server = response["server"]
        state[:server_id] = server["id"]
        state[:server_name] = server["name"]

        with_api_errors do
          client.wait_for_action(response["action"], timeout: config[:server_ready_timeout])
        end

        state[:hostname] = public_ip(server) || public_ip(with_api_errors { client.server(server["id"]) })
        state[:username] = config[:username]
        state[:port] = config[:port]

        if state[:hostname].nil?
          raise Kitchen::ActionFailed,
            "Hetzner server <#{state[:server_id]}> came up without a public IPv4 " \
            "address. kitchen-hetzner needs public IPv4 to reach the instance."
        end

        info("Hetzner server <#{state[:server_id]}> is up at #{state[:hostname]}.")
      end

      # Blocks until the instance's transport reports the server reachable.
      #
      # @param state [Hash] mutable instance state
      # @return [void]
      def await_ssh(state)
        info("Waiting for #{state[:hostname]} to become ready...")
        instance.transport.connection(state).wait_until_ready
        info("Hetzner instance <#{state[:server_id]}> ready.")
      end

      # Best-effort teardown of resources left behind by a failed create.
      #
      # Any error here is logged and swallowed: the caller is already raising a
      # more useful error about why creation failed.
      #
      # @param state [Hash] mutable instance state
      # @return [void]
      def cleanup_after_failed_create(state)
        return unless state[:server_id] || state[:hetzner_ssh_key_id] || state[:hetzner_ssh_key_path]

        warn("Cleaning up partially created Hetzner resources after a failed create...")
        destroy(state)
      rescue => e
        warn("Could not clean up after the failed create: #{e.message}")
      end

      # Deletes the throwaway SSH key, if this driver created one.
      #
      # @param state [Hash] mutable instance state
      # @return [void]
      def destroy_ephemeral_key(state)
        key_id = state.delete(:hetzner_ssh_key_id)
        ssh_key = state.delete(:ssh_key)

        # Deleted whenever this driver wrote it, even with no key_id: the file
        # is written before the upload, so a create that failed at the upload
        # leaves a private key on disk with no Hetzner key to match it. The
        # fallback covers state files written before the path was recorded
        # separately, and is only safe because a key we uploaded implies a key
        # we generated.
        path = state.delete(:hetzner_ssh_key_path) || (key_id ? ssh_key : nil)

        if key_id
          debug("Deleting ephemeral Hetzner SSH key <#{key_id}>")
          with_api_errors { client.delete_ssh_key(key_id) }
        end

        File.delete(path) if path && File.exist?(path)
      end

      # Describes a create failure for the error Test Kitchen shows the user.
      #
      # Test Kitchen's own errors already read well on their own. Anything else
      # -- an Errno from writing the key file, a bug in this driver -- is not
      # identifiable without its class name.
      #
      # @param error [::StandardError] the failure to describe
      # @return [String] the message to raise
      def error_summary(error)
        return error.message if error.is_a?(Kitchen::Error) || error.is_a?(Hcloud::ApiError)

        "#{error.class}: #{error.message}"
      end

      # Extracts the public IPv4 address from a server hash.
      #
      # @param server [Hash, nil] a server as returned by the API
      # @return [String, nil] the address, or nil if none is assigned
      def public_ip(server)
        ip = server&.dig("public_net", "ipv4", "ip")
        ip if ip && !ip.empty?
      end

      # Labels applied to every resource this driver creates.
      #
      # @return [Hash{String => String}] the base label set
      def base_labels
        { "created_by" => CREATED_BY }
      end

      # Labels applied to created servers, including any user-supplied ones.
      #
      # @return [Hash{String => String}] the server label set
      def server_labels
        user_labels = (config[:labels] || {}).map { |k, v| [k.to_s, sanitize_label(v)] }.to_h

        base_labels
          .merge("kitchen_instance" => sanitize_label(instance.name))
          .merge(user_labels)
      end

      # Coerces a value into something Hetzner accepts as a label value.
      #
      # Hetzner allows alphanumerics, dashes, underscores and dots, up to 63
      # characters, and the value must start and end with an alphanumeric.
      #
      # @param value [Object] the raw value
      # @return [String] a valid label value
      def sanitize_label(value)
        value.to_s.gsub(/[^A-Za-z0-9_.-]/, "-")[0, MAX_NAME_LENGTH].gsub(/\A[^A-Za-z0-9]+|[^A-Za-z0-9]+\z/, "")
      end

      # Builds a server name that is unique within the Hetzner project.
      #
      # Hetzner server names must be valid RFC 1123 hostnames and unique per
      # project, so the instance name alone would collide between concurrent CI
      # runs against the same project.
      #
      # @param base [String] the name to derive from, usually the instance name
      # @return [String] a sanitized, suffixed, length-capped name
      def unique_name(base)
        suffix = "-#{SecureRandom.hex(3)}"
        clean = base.to_s.downcase.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").gsub(/\A-+|-+\z/, "")
        clean = "kitchen" if clean.empty?

        "#{clean[0, MAX_NAME_LENGTH - suffix.length]}#{suffix}"
      end

      # Path for the generated private key belonging to this instance.
      #
      # @return [String] an absolute path inside the kitchen cache directory
      def ephemeral_key_path
        root = config[:kitchen_root] || Dir.pwd
        File.join(root, ".kitchen", "hetzner", "#{instance.name}.pem")
      end

      # Collects every server ID recorded in local Test Kitchen state files.
      #
      # @param state [Hash] this instance's state, always considered known
      # @return [Array<Integer>] known server IDs
      def known_server_ids(state)
        root = config[:kitchen_root] || Dir.pwd
        ids = [state[:server_id]].compact

        Dir.glob(File.join(root, ".kitchen", "*.yml")).each do |file|
          data = YAML.safe_load_file(file, permitted_classes: [Symbol])
          id = data.is_a?(Hash) ? data[:server_id] || data["server_id"] : nil
          ids << id if id
        rescue ::StandardError => e
          debug("Skipping unreadable state file #{file}: #{e.message}")
        end

        ids.uniq
      end

      # Prints a table of orphaned servers and how to remove them.
      #
      # @param orphans [Array<Hash>] servers with no local state
      # @return [void]
      def report_orphans(orphans)
        warn("Found #{orphans.length} Hetzner server(s) labelled created_by=#{CREATED_BY} with no local Test Kitchen state:")
        warn("  #{"ID".ljust(12)} #{"NAME".ljust(40)} CREATED")

        orphans.each do |server|
          warn(format("  %-12<id>s %-40<name>s %<created>s",
            id: server["id"], name: server["name"].to_s[0, 40], created: server["created"]))
        end

        warn("These are not destroyed automatically. Remove them with:")
        warn("  hcloud server delete #{orphans.map { |s| s["id"] }.join(" ")}")
      end

      # Builds an unknown/derived status hash for `kitchen status`.
      #
      # @param message [String] why the status is what it is
      # @param live [Boolean, nil] liveness, if known
      # @param state [String] a short state label
      # @return [Hash] normalized status data
      def unknown_status(message, live: nil, state: "unknown")
        {
          live: live,
          state: state,
          source: "driver",
          resource_id: nil,
          message: message,
          checked_at: Time.now.utc.iso8601,
        }
      end

      # Runs a block, converting API errors into Test Kitchen action failures.
      #
      # @yield the API call to perform
      # @return [Object] whatever the block returns
      # @raise [Kitchen::ActionFailed] if the block raises {Hcloud::ApiError}
      def with_api_errors
        yield
      rescue Hcloud::ApiError => e
        raise Kitchen::ActionFailed, e.message
      end
    end
  end
end
