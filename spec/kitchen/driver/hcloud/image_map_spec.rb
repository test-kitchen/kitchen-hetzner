require "spec_helper"

RSpec.describe Kitchen::Driver::Hcloud::ImageMap do
  describe ".image_for" do
    it "passes through platform names that already match Hetzner slugs" do
      {
        "ubuntu-24.04" => "ubuntu-24.04",
        "ubuntu-22.04" => "ubuntu-22.04",
        "debian-12" => "debian-12",
        "rocky-9" => "rocky-9",
        "fedora-42" => "fedora-42",
      }.each do |platform, expected|
        expect(described_class.image_for(platform)).to eq(expected)
      end
    end

    it "renames families whose Test Kitchen name differs from the Hetzner slug" do
      expect(described_class.image_for("almalinux-9")).to eq("alma-9")
      expect(described_class.image_for("almalinux-8")).to eq("alma-8")
    end

    it "leaves multi-part family names intact" do
      expect(described_class.image_for("centos-stream-9")).to eq("centos-stream-9")
      expect(described_class.image_for("centos-stream-10")).to eq("centos-stream-10")
    end

    it "handles a family with no version suffix" do
      expect(described_class.image_for("almalinux")).to eq("alma")
      expect(described_class.image_for("ubuntu")).to eq("ubuntu")
    end

    it "normalizes case and surrounding whitespace" do
      expect(described_class.image_for("  Ubuntu-24.04 ")).to eq("ubuntu-24.04")
      expect(described_class.image_for("AlmaLinux-9")).to eq("alma-9")
    end

    it "returns nil for blank input" do
      expect(described_class.image_for(nil)).to be_nil
      expect(described_class.image_for("")).to be_nil
      expect(described_class.image_for("   ")).to be_nil
    end
  end

  describe ".unsupported?" do
    it "flags Windows, which Hetzner Cloud does not offer" do
      expect(described_class.unsupported?("windows-2022")).to be true
      expect(described_class.unsupported?("windows-2019")).to be true
      expect(described_class.unsupported?("Windows-2022")).to be true
    end

    it "does not flag Linux platforms" do
      %w{ubuntu-24.04 debian-12 almalinux-9 rocky-9 centos-stream-9}.each do |platform|
        expect(described_class.unsupported?(platform)).to be false
      end
    end

    it "does not flag blank input" do
      expect(described_class.unsupported?(nil)).to be false
      expect(described_class.unsupported?("")).to be false
    end
  end
end
