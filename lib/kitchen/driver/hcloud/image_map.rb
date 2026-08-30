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
    module Hcloud
      # Translates Test Kitchen platform names into Hetzner Cloud image slugs.
      #
      # Most Test Kitchen platform names already match Hetzner's slugs exactly,
      # so the default behaviour is a straight pass-through. Only genuine
      # mismatches need an entry in {FAMILY_ALIASES}, which keeps the table
      # small and unlikely to drift as Hetzner adds images.
      #
      # An explicit `image` in the driver config always wins over this mapping.
      #
      # @example
      #   ImageMap.image_for("ubuntu-24.04")  #=> "ubuntu-24.04"
      #   ImageMap.image_for("almalinux-9")   #=> "alma-9"
      module ImageMap
        # Distribution families whose Test Kitchen name differs from the
        # Hetzner Cloud image slug.
        #
        # @return [Hash{String => String}]
        FAMILY_ALIASES = {
          "almalinux" => "alma",
          "rockylinux" => "rocky",
        }.freeze

        # Platform name prefixes that Hetzner Cloud cannot boot at all.
        #
        # Hetzner Cloud offers no Windows images, so pointing a Windows platform
        # at this driver can never work. Detecting it here lets the driver fail
        # with an explanation instead of a bare HTTP 404 from the API.
        #
        # @return [Array<String>]
        UNSUPPORTED_FAMILIES = %w{windows}.freeze

        # Converts a Test Kitchen platform name into a Hetzner image slug.
        #
        # @param platform_name [String, nil] the Test Kitchen platform name
        # @return [String, nil] the image slug, or `nil` for a blank input
        # @example A family that needs renaming
        #   ImageMap.image_for("almalinux-9") #=> "alma-9"
        # @example A family that passes straight through
        #   ImageMap.image_for("centos-stream-9") #=> "centos-stream-9"
        def self.image_for(platform_name)
          slug = platform_name.to_s.strip.downcase
          return nil if slug.empty?

          family, remainder = slug.split("-", 2)
          mapped = FAMILY_ALIASES.fetch(family, family)

          remainder.nil? ? mapped : "#{mapped}-#{remainder}"
        end

        # Reports whether a platform is one Hetzner Cloud cannot run.
        #
        # @param platform_name [String, nil] the Test Kitchen platform name
        # @return [Boolean] true if the platform can never boot on Hetzner Cloud
        def self.unsupported?(platform_name)
          family = platform_name.to_s.strip.downcase.split("-", 2).first
          UNSUPPORTED_FAMILIES.include?(family)
        end
      end
    end
  end
end
