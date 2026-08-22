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

require "fileutils" unless defined?(FileUtils)
require "openssl" unless defined?(OpenSSL)

module Kitchen
  module Driver
    module Hcloud
      # Generates the throwaway SSH keypair used when the user has not named an
      # existing Hetzner SSH key.
      #
      # RSA is used rather than Ed25519 on purpose. Ruby's bundled `openssl`
      # cannot generate Ed25519 keys, and `net-ssh` needs the `ed25519` and
      # `bcrypt_pbkdf` gems to consume one. Using RSA keeps this driver free of
      # runtime dependencies, which matters because it ships inside Cinc
      # Workstation and Chef Workstation.
      #
      # @example
      #   key = SshKey.generate
      #   key.openssh_public_key(comment: "kitchen")  #=> "ssh-rsa AAAAB3Nz... kitchen"
      #   key.write("/path/to/id_rsa")
      class SshKey
        # @return [Integer] default RSA modulus size
        DEFAULT_BITS = 3072

        # @return [OpenSSL::PKey::RSA] the underlying keypair
        attr_reader :rsa

        # @param rsa [OpenSSL::PKey::RSA] an existing keypair to wrap
        def initialize(rsa)
          @rsa = rsa
        end

        # Generates a fresh keypair.
        #
        # @param bits [Integer] the RSA modulus size
        # @return [SshKey] the generated key
        def self.generate(bits: DEFAULT_BITS)
          new(OpenSSL::PKey::RSA.new(bits))
        end

        # Renders the public key in OpenSSH `authorized_keys` format.
        #
        # The wire format is a base64-encoded blob of three SSH strings: the
        # algorithm name, the RSA public exponent, and the modulus. See RFC 4253
        # section 6.6.
        #
        # @param comment [String] trailing comment for the key
        # @return [String] the key, e.g. `"ssh-rsa AAAAB3Nza... kitchen"`
        def openssh_public_key(comment: "")
          blob = ssh_string("ssh-rsa") + ssh_mpint(rsa.e) + ssh_mpint(rsa.n)
          encoded = [blob].pack("m0")

          comment.to_s.empty? ? "ssh-rsa #{encoded}" : "ssh-rsa #{encoded} #{comment}"
        end

        # Writes the private key to disk with owner-only permissions.
        #
        # @param path [String] destination path
        # @return [String] the path written
        def write(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, rsa.to_pem)
          FileUtils.chmod(0600, path)
          path
        end

        private

        # Encodes a byte string as an SSH `string`: a 4-byte big-endian length
        # followed by the bytes themselves.
        #
        # @param value [String] the bytes to encode
        # @return [String] the encoded string, binary
        def ssh_string(value)
          bytes = value.dup.force_encoding(Encoding::BINARY)
          [bytes.bytesize].pack("N") + bytes
        end

        # Encodes an OpenSSL big number as an SSH `mpint`.
        #
        # An mpint is two's-complement and signed, so a leading zero byte is
        # prepended whenever the high bit is set. Without it the value would be
        # read back as negative and the key would be rejected.
        #
        # @param bn [OpenSSL::BN] the number to encode
        # @return [String] the encoded mpint, binary
        def ssh_mpint(bn)
          bytes = bn.to_s(2).force_encoding(Encoding::BINARY)
          bytes = "\x00".dup.force_encoding(Encoding::BINARY) + bytes if bytes.empty? || bytes.getbyte(0) >= 0x80

          ssh_string(bytes)
        end
      end
    end
  end
end
