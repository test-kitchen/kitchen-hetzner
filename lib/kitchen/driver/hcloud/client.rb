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

require "json" unless defined?(JSON)
require "net/http" unless defined?(Net::HTTP)
require "openssl" unless defined?(OpenSSL)
require "uri" unless defined?(URI)

require_relative "api_error"

module Kitchen
  module Driver
    module Hcloud
      # A small, dependency-free client for the parts of the Hetzner Cloud API
      # that Test Kitchen needs: servers, SSH keys, and actions.
      #
      # This deliberately avoids a third-party API gem. The driver ships inside
      # Cinc Workstation and Chef Workstation, where every added dependency (and
      # especially every native extension) is a packaging liability. The API
      # surface used here is small enough that `Net::HTTP` is the cheaper trade.
      #
      # @example Creating a server and waiting for it to boot
      #   client = Client.new(token: ENV["HCLOUD_TOKEN"])
      #   result = client.create_server(
      #     name: "kitchen-default-ubuntu-2404-a1b2c3",
      #     server_type: "cx22",
      #     image: "ubuntu-24.04",
      #     location: "fsn1",
      #     ssh_keys: ["my-key"]
      #   )
      #   client.wait_for_action(result["action"])
      class Client
        # @return [String] the default Hetzner Cloud API root
        API_ROOT = "https://api.hetzner.cloud/v1".freeze

        # @return [Array<Integer>] HTTP statuses worth retrying
        RETRIABLE_STATUSES = [429, 500, 502, 503, 504].freeze

        # @return [Integer] how many times to retry a retriable failure
        MAX_RETRIES = 5

        # @return [Integer] seconds to wait for a connection to open
        OPEN_TIMEOUT = 10

        # @return [Integer] seconds to wait for a response body
        READ_TIMEOUT = 30

        # @return [Integer] default seconds to wait for an action to finish
        ACTION_TIMEOUT = 600

        # @return [Integer] default seconds between action status polls
        ACTION_INTERVAL = 2

        # @return [Integer] page size used when listing paginated collections
        PER_PAGE = 50

        # Network-level failures that are safe to retry.
        #
        # Every request this client makes is either idempotent or a create that
        # a failed connection means never happened, so the list is deliberately
        # broad. Anything missing from it does not merely skip the retry: it
        # escapes as a raw exception rather than an {ApiError}, and the driver
        # reports an unexpected crash instead of an action failure.
        RETRIABLE_EXCEPTIONS = [
          Errno::ECONNABORTED,
          Errno::ECONNREFUSED,
          Errno::ECONNRESET,
          Errno::EHOSTUNREACH,
          Errno::ENETDOWN,
          Errno::ENETRESET,
          Errno::ENETUNREACH,
          Errno::EPIPE,
          Errno::ETIMEDOUT,
          # EOFError is an IOError; Net::OpenTimeout and Net::ReadTimeout are
          # both Timeout::Error. Net::HTTPBadResponse is neither -- it is a bare
          # StandardError -- so it has to be named.
          IOError,
          Timeout::Error,
          Net::HTTPBadResponse,
          # A TLS handshake reset mid-flight. Not an IOError, and the one this
          # list most often lacked.
          OpenSSL::SSL::SSLError,
          SocketError,
        ].freeze

        # @return [String] the API root this client talks to
        attr_reader :api_root

        # @param token [String] a Hetzner Cloud API token with read/write scope
        # @param logger [#debug, nil] optional logger for request tracing
        # @param api_root [String] override the API root, mainly for testing
        # @param max_retries [Integer] how many times to retry retriable failures
        # @param sleeper [#call] callable used to sleep between retries and
        #   action polls. Injected so that tests can run without real delays.
        # @raise [ArgumentError] if no token is supplied
        def initialize(token:, logger: nil, api_root: API_ROOT, max_retries: MAX_RETRIES, sleeper: nil)
          raise ArgumentError, "a Hetzner Cloud API token is required" if token.nil? || token.to_s.empty?

          @token = token
          @logger = logger
          @api_root = api_root
          @max_retries = max_retries
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        end

        # Creates a server.
        #
        # @param name [String] the server name, must be a valid RFC 1123 hostname
        # @param server_type [String] a Hetzner server type slug, e.g. `"cx22"`
        # @param image [String, Integer] an image slug or a snapshot ID
        # @param location [String, nil] a location slug, e.g. `"fsn1"`
        # @param ssh_keys [Array<String, Integer>] SSH key names or IDs to inject
        # @param user_data [String, nil] cloud-init user data
        # @param labels [Hash] labels to attach to the server
        # @return [Hash] the parsed API response, including `"server"` and `"action"`
        # @raise [ApiError] if the API rejects the request
        def create_server(name:, server_type:, image:, location: nil, ssh_keys: [], user_data: nil, labels: {})
          body = {
            name: name,
            server_type: server_type,
            image: image,
            start_after_create: true,
          }
          body[:location] = location if location
          body[:ssh_keys] = ssh_keys unless ssh_keys.nil? || ssh_keys.empty?
          body[:user_data] = user_data if user_data && !user_data.empty?
          body[:labels] = labels unless labels.nil? || labels.empty?

          request(:post, "/servers", body: body)
        end

        # Fetches a single server.
        #
        # @param id [Integer, String] the server ID
        # @return [Hash, nil] the server hash, or `nil` if it no longer exists
        # @raise [ApiError] for any error other than a missing server
        def server(id)
          request(:get, "/servers/#{id}")["server"]
        rescue ApiError => e
          raise unless e.status == 404

          nil
        end

        # Deletes a server.
        #
        # A server that is already gone is treated as success, because Test
        # Kitchen frequently re-runs `destroy` against stale state files.
        #
        # @param id [Integer, String] the server ID
        # @return [Boolean] true if this call deleted the server, false if it
        #   was already absent
        # @raise [ApiError] for any error other than a missing server
        def delete_server(id)
          request(:delete, "/servers/#{id}")
          true
        rescue ApiError => e
          raise unless e.status == 404

          false
        end

        # Lists servers, following pagination to the end.
        #
        # @param label_selector [String, nil] a Hetzner label selector,
        #   e.g. `"created_by=test-kitchen"`
        # @return [Array<Hash>] every matching server
        # @raise [ApiError] if the API rejects the request
        def servers(label_selector: nil)
          query = {}
          query[:label_selector] = label_selector if label_selector
          paginate("/servers", "servers", query)
        end

        # Uploads an SSH public key to the project.
        #
        # @param name [String] a project-unique name for the key
        # @param public_key [String] the key in OpenSSH format
        # @param labels [Hash] labels to attach to the key
        # @return [Hash] the created SSH key
        # @raise [ApiError] if the API rejects the request
        def create_ssh_key(name:, public_key:, labels: {})
          body = { name: name, public_key: public_key }
          body[:labels] = labels unless labels.nil? || labels.empty?
          request(:post, "/ssh_keys", body: body)["ssh_key"]
        end

        # Deletes an SSH key, tolerating a key that is already gone.
        #
        # @param id [Integer, String] the SSH key ID
        # @return [Boolean] true if this call deleted the key
        # @raise [ApiError] for any error other than a missing key
        def delete_ssh_key(id)
          request(:delete, "/ssh_keys/#{id}")
          true
        rescue ApiError => e
          raise unless e.status == 404

          false
        end

        # Fetches a single action.
        #
        # @param id [Integer, String] the action ID
        # @return [Hash] the action hash
        # @raise [ApiError] if the API rejects the request
        def action(id)
          request(:get, "/actions/#{id}")["action"]
        end

        # Blocks until an action reaches a terminal state.
        #
        # @param action_hash [Hash] an action as returned by another API call
        # @param timeout [Integer] seconds to wait before giving up
        # @param interval [Integer] seconds between polls
        # @return [Hash] the completed action
        # @raise [ApiError] if the action fails or does not finish in time
        def wait_for_action(action_hash, timeout: ACTION_TIMEOUT, interval: ACTION_INTERVAL)
          return action_hash if action_hash.nil?

          current = action_hash
          deadline = monotonic_time + timeout

          while current["status"] == "running"
            if monotonic_time >= deadline
              raise ApiError.new(
                "Timed out after #{timeout}s waiting for Hetzner action " \
                "#{current["command"]} (##{current["id"]}) to complete",
                code: "action_timeout"
              )
            end

            @sleeper.call(interval)
            current = action(current["id"])
          end

          return current if current["status"] == "success"

          error = current["error"] || {}
          raise ApiError.new(
            "Hetzner action #{current["command"]} (##{current["id"]}) failed: " \
            "#{error["message"] || "unknown error"}",
            code: error["code"]
          )
        end

        private

        # Walks every page of a paginated collection.
        #
        # @param path [String] the API path
        # @param key [String] the response key holding the collection
        # @param query [Hash] additional query parameters
        # @return [Array<Hash>] the combined results
        def paginate(path, key, query = {})
          results = []
          page = 1

          loop do
            response = request(:get, path, query: query.merge(page: page, per_page: PER_PAGE))
            results.concat(response[key] || [])

            next_page = response.dig("meta", "pagination", "next_page")
            # A next_page that does not advance would loop forever, appending
            # the same page to the results until the process runs out of memory.
            break if next_page.nil? || next_page.to_i <= page

            page = next_page
          end

          results
        end

        # Performs an HTTP request, retrying transient failures.
        #
        # @param method [Symbol] `:get`, `:post`, or `:delete`
        # @param path [String] the API path, beginning with a slash
        # @param body [Hash, nil] a request body to serialize as JSON
        # @param query [Hash] query parameters
        # @return [Hash] the parsed response body, or an empty hash for 204s
        # @raise [ApiError] if the request ultimately fails
        def request(method, path, body: nil, query: {})
          attempt = 0

          begin
            attempt += 1
            handle(execute(method, path, body, query), method, path, attempt)
          rescue RetryRequested
            retry
          rescue *RETRIABLE_EXCEPTIONS => e
            raise ApiError.new("Hetzner API request failed: #{e.class}: #{e.message}") if attempt > @max_retries

            backoff(attempt, "#{e.class}: #{e.message}")
            retry
          end
        end

        # Interprets an HTTP response, retrying or raising as appropriate.
        #
        # @param response [Net::HTTPResponse] the raw response
        # @param method [Symbol] the HTTP method, for error messages
        # @param path [String] the API path, for error messages
        # @param attempt [Integer] the current attempt number
        # @return [Hash] the parsed body
        # @raise [ApiError] if the response is an unrecoverable error
        def handle(response, method, path, attempt)
          status = response.code.to_i
          parsed = parse_body(response.body)

          return parsed if status.between?(200, 299)

          if RETRIABLE_STATUSES.include?(status) && attempt <= @max_retries
            backoff(attempt, "HTTP #{status}", retry_after: response["retry-after"])
            raise RetryRequested
          end

          raise build_error(status, parsed, method, path)
        end

        # Builds a descriptive error from a failed response.
        #
        # @param status [Integer] the HTTP status code
        # @param parsed [Hash] the parsed response body
        # @param method [Symbol] the HTTP method
        # @param path [String] the API path
        # @return [ApiError] the error to raise
        def build_error(status, parsed, method, path)
          error = parsed["error"] || {}
          code = error["code"]
          message = error["message"] || "HTTP #{status}"

          detail =
            if status == 401
              "Hetzner API authentication failed (#{message}). Check that your " \
              "token is valid and set via the hetzner_token driver option or " \
              "the HCLOUD_TOKEN environment variable."
            else
              "Hetzner API request #{method.to_s.upcase} #{path} failed with " \
              "HTTP #{status}: #{message}"
            end

          ApiError.new(detail, code: code, status: status)
        end

        # Issues a single HTTP request with no retry handling.
        #
        # @param method [Symbol] the HTTP method
        # @param path [String] the API path
        # @param body [Hash, nil] the request body
        # @param query [Hash] query parameters
        # @return [Net::HTTPResponse] the raw response
        def execute(method, path, body, query)
          uri = URI.parse("#{@api_root}#{path}")
          uri.query = URI.encode_www_form(query) unless query.nil? || query.empty?

          req = request_class(method).new(uri)
          req["Authorization"] = "Bearer #{@token}"
          req["Accept"] = "application/json"
          req["User-Agent"] = "kitchen-hetzner/#{Kitchen::Driver::HETZNER_VERSION}"

          if body
            req["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          end

          @logger&.debug("[hetzner] #{method.to_s.upcase} #{uri}")

          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            http.request(req)
          end
        end

        # Maps an HTTP verb to its `Net::HTTP` request class.
        #
        # @param method [Symbol] `:get`, `:post`, or `:delete`
        # @return [Class] the matching request class
        # @raise [ArgumentError] for an unsupported verb
        def request_class(method)
          case method
          when :get then Net::HTTP::Get
          when :post then Net::HTTP::Post
          when :delete then Net::HTTP::Delete
          else raise ArgumentError, "unsupported HTTP method: #{method}"
          end
        end

        # Parses a JSON response body, tolerating empty or malformed bodies.
        #
        # @param body [String, nil] the raw response body
        # @return [Hash] the parsed body, or an empty hash
        def parse_body(body)
          return {} if body.nil? || body.strip.empty?

          JSON.parse(body)
        rescue JSON::ParserError
          {}
        end

        # Sleeps for an exponentially increasing interval.
        #
        # @param attempt [Integer] the attempt number, used as the exponent
        # @param reason [String] why we are backing off, for logging
        # @param retry_after [String, nil] a `Retry-After` header value to honour
        # @return [void]
        def backoff(attempt, reason, retry_after: nil)
          seconds = retry_after&.to_i
          seconds = 2**(attempt - 1) if seconds.nil? || seconds <= 0

          @logger&.debug("[hetzner] retrying after #{seconds}s (#{reason})")
          @sleeper.call(seconds)
        end

        # Reads a monotonic clock, so that a system clock change cannot make a
        # wait loop hang or exit early.
        #
        # @return [Float] seconds from an arbitrary fixed point
        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # Internal signal used to drive the retry loop in {#request}.
        class RetryRequested < ::StandardError; end
        private_constant :RetryRequested
      end
    end
  end
end
