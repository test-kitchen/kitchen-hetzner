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

module Kitchen
  module Driver
    # Supporting classes for the Hetzner Cloud driver: the API client, the
    # platform-to-image mapping, and ephemeral SSH key generation.
    #
    # These live in their own namespace rather than inside
    # {Kitchen::Driver::Hetzner} so that requiring any one of them cannot
    # trigger a superclass mismatch on the driver class itself.
    module Hcloud
      # Raised when the Hetzner Cloud API returns an error response, or when a
      # server action reports a failure.
      #
      # The driver rescues this and re-raises it as {Kitchen::ActionFailed} so
      # that Test Kitchen reports it as an expected action failure rather than
      # an unexpected crash.
      # Note the explicit `::` — inside `module Kitchen`, a bare
      # `StandardError` resolves to {Kitchen::StandardError}, whose
      # constructor requires a message and wraps `$ERROR_INFO`.
      class ApiError < ::StandardError
        # @return [String, nil] the machine-readable Hetzner error code,
        #   for example `"unauthorized"` or `"uniqueness_error"`
        attr_reader :code

        # @return [Integer, nil] the HTTP status code, when the error came from
        #   an HTTP response rather than a failed action
        attr_reader :status

        # @param message [String] the human-readable error message
        # @param code [String, nil] the Hetzner error code
        # @param status [Integer, nil] the HTTP status code
        def initialize(message, code: nil, status: nil)
          @code = code
          @status = status
          super(message)
        end
      end
    end
  end
end
