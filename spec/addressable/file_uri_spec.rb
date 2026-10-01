# frozen_string_literal: true

require "spec_helper"
require "addressable/uri"

describe Addressable::URI, "RFC 8089 file URI conversion" do
  let(:filesystem_probe) do
    lambda do
      allow(File).to receive(:exist?).and_raise("File.exist? must not be called")
      allow(File).to receive(:stat).and_raise("File.stat must not be called")
    end
  end

  before do
    filesystem_probe.call
  end

  def round_trip(path, platform, base=nil)
    uri = described_class.path_to_file_uri(path, platform, base)
    described_class.file_uri_to_path(uri, platform, base)
  end

  it "round-trips the required POSIX and Windows string fixtures" do
    fixtures = [
      ["/tmp/my folder/100%25/中文.txt", :posix, nil],
      ["relative/a b/100%25/中文.txt", :posix, "/base/dir"],
      ["C:\\My Folder\\100%25\\中文.txt", :windows, nil],
      ["relative\\a b\\100%25\\中文.txt", :windows, "E:\\base"],
      ["\\\\SERVER\\Share Name\\100%25\\中文.txt", :windows, nil],
      ["\\\\localhost\\Share\\100%25\\中文.txt", :windows, nil]
    ]

    fixtures.each do |path, platform, base|
      separator = platform == :windows ? "\\" : "/"
      expected = base ? "#{base}#{separator}#{path}" : path
      expect(round_trip(path, platform, base)).to eq(expected)
    end
  end

  shared_examples "filesystem-free file conversion" do
    it "completes while filesystem probes are raising stubs" do
      run_conversions
    end
  end

  describe ".path_to_file_uri" do
    context "with POSIX paths" do
      it "encodes spaces, percent signs and Unicode" do
        path = "/tmp/my folder/100%25/中文.txt"
        uri = described_class.path_to_file_uri(path, :posix)

        expect(uri.to_s).to eq(
          "file:///tmp/my%20folder/100%2525/%E4%B8%AD%E6%96%87.txt"
        )
      end

      it "preserves trailing slash, dot and space characters" do
        path = "/tmp/directory./trailing space "
        expect(round_trip(path, :posix)).to eq(path)
      end

      it "accepts a relative path with an absolute POSIX base" do
        uri = described_class.path_to_file_uri(
          "notes/a b.txt", :posix, "/home/user/Downloads"
        )

        expect(uri.to_s).to eq(
          "file:///home/user/Downloads/notes/a%20b.txt"
        )
      end

      it "accepts a file URI base" do
        uri = described_class.path_to_file_uri(
          "notes.txt", platform: :posix, base: "file:///home/user/"
        )

        expect(uri.to_s).to eq("file:///home/user/notes.txt")
      end

      it "accepts platform and base as keyword options" do
        uri = described_class.path_to_file_uri(
          "notes.txt", platform: "posix", base: "/home/user/"
        )
        path = described_class.file_uri_to_path(
          uri, platform: "posix", base: "/home/user/"
        )

        expect(uri.to_s).to eq("file:///home/user/notes.txt")
        expect(path).to eq("/home/user/notes.txt")
      end

      it "rejects relative paths without a same-platform absolute base" do
        expect do
          described_class.path_to_file_uri("relative.txt", :posix)
        end.to raise_error(Addressable::URI::InvalidFileURIError)
      end

      it "rejects NUL" do
        expect { described_class.path_to_file_uri("/a\x00b", :posix) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
      end

      it_behaves_like "filesystem-free file conversion" do
        let(:run_conversions) do
          round_trip("/tmp/my folder/100%25/中文.txt", :posix)
        end
      end
    end

    context "with Windows paths" do
      it "converts drive absolute paths" do
        path = "C:\\Users\\My Documents\\100%25\\中文.txt"
        uri = described_class.path_to_file_uri(path, :windows)

        expect(uri.to_s).to eq(
          "file:///C:/Users/My%20Documents/100%2525/%E4%B8%AD%E6%96%87.txt"
        )
      end

      it "converts forward-slash drive paths and UNC paths" do
        expect(described_class.path_to_file_uri("D:/a b.txt", :windows).to_s).
          to eq("file:///D:/a%20b.txt")
        expect(
          described_class.path_to_file_uri("\\\\SERVER\\Share\\a b.txt", :windows).to_s
        ).to eq("file://SERVER/Share/a%20b.txt")
      end

      it "maps a localhost UNC authority back to a UNC path on Windows" do
        expect(
          described_class.file_uri_to_path(
            "file://localhost/Share/a%20b.txt", :windows
          )
        ).to eq("\\\\localhost\\Share\\a b.txt")
      end

      it "preserves UNC trailing characters" do
        path = "\\\\server\\share\\folder.\\trailing space "
        expect(round_trip(path, :windows)).to eq(path)
      end

      it "accepts a relative path with an absolute drive or UNC base" do
        uri = described_class.path_to_file_uri(
          "..\\a.txt", :windows, "C:\\Users\\me"
        )
        expect(uri.to_s).to eq("file:///C:/Users/me/../a.txt")

        uri = described_class.path_to_file_uri(
          "a.txt", :windows, "\\\\server\\share\\dir"
        )
        expect(uri.to_s).to eq("file://server/share/dir/a.txt")
      end

      it "rejects drive-relative, root-relative and device paths" do
        expect { described_class.path_to_file_uri("C:relative.txt", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.path_to_file_uri("\\relative.txt", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.path_to_file_uri("\\\\.\\C:\\a", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.path_to_file_uri("\\\\?\\C:\\a", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
      end

      it "rejects NUL, reserved names and incomplete UNC paths" do
        expect { described_class.path_to_file_uri("C:\\a\x00b", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.path_to_file_uri("C:\\NUL", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.path_to_file_uri("\\\\server", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.path_to_file_uri("\\\\?\\UNC\\server\\share", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
      end

      it_behaves_like "filesystem-free file conversion" do
        let(:run_conversions) do
          round_trip("C:\\Users\\My Documents\\100%25\\中文.txt", :windows)
        end
      end
    end

    it "requires an explicit supported platform" do
      expect { described_class.path_to_file_uri("/a", :plan9) }.
        to raise_error(ArgumentError)
    end
  end

  describe ".file_uri_to_path" do
    context "with POSIX" do
      it "decodes localhost, spaces, percent signs and Unicode" do
        path = described_class.file_uri_to_path(
          "file://localhost/tmp/my%20folder/100%2525/%E4%B8%AD%E6%96%87.txt",
          :posix
        )

        expect(path).to eq("/tmp/my folder/100%25/中文.txt")
      end

      it "resolves relative references against an absolute base" do
        expect(
          described_class.file_uri_to_path(
            "file:notes/a%20b.txt", :posix, "file:///home/user/Downloads"
          )
        ).to eq("/home/user/Downloads/notes/a b.txt")
      end

      it "rejects remote authorities and encoded separators" do
        expect { described_class.file_uri_to_path("file://host/a", :posix) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.file_uri_to_path("file:///a%2Fb", :posix) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
      end
    end

    context "with Windows" do
      it "decodes drive, legacy pipe and UNC URIs" do
        expect(described_class.file_uri_to_path("file:///C:/a%20b.txt", :windows)).
          to eq("C:\\a b.txt")
        expect(described_class.file_uri_to_path("file:///D|/a.txt", :windows)).
          to eq("D:\\a.txt")
        expect(described_class.file_uri_to_path("file://server/share/a%20b.txt", :windows)).
          to eq("\\\\server\\share\\a b.txt")
      end

      it "treats localhost drive URIs as local but rejects empty-host root-relative URIs" do
        expect(
          described_class.file_uri_to_path("file://localhost/C:/a.txt", :windows)
        ).to eq("C:\\a.txt")
        expect do
          described_class.file_uri_to_path("file:///Windows/a.txt", :windows)
        end.to raise_error(Addressable::URI::InvalidFileURIError)
      end

      it "resolves relative references against Windows bases" do
        expect(
          described_class.file_uri_to_path(
            "file:../a.txt", :windows, "file:///C:/Users/me"
          )
        ).to eq("C:\\Users\\me\\..\\a.txt")
      end

      it "rejects encoded backslashes, malformed encoding and NUL" do
        expect { described_class.file_uri_to_path("file:///C:/a%5Cb", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.file_uri_to_path("file:///C:/a%2", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
        expect { described_class.file_uri_to_path("file:///C:/a%00b", :windows) }.
          to raise_error(Addressable::URI::InvalidFileURIError)
      end

      it "rejects drive-relative URIs even when a base is supplied" do
        expect do
          described_class.file_uri_to_path(
            "file:C:relative.txt", :windows, "file:///D:/base"
          )
        end.to raise_error(Addressable::URI::InvalidFileURIError)
      end
    end

    it "rejects query, fragment, non-file schemes and unsupported platforms" do
      expect { described_class.file_uri_to_path("file:///a?x=1", :posix) }.
        to raise_error(Addressable::URI::InvalidFileURIError)
      expect { described_class.file_uri_to_path("file:///a#x", :posix) }.
        to raise_error(Addressable::URI::InvalidFileURIError)
      expect { described_class.file_uri_to_path("http://example.com/a", :posix) }.
        to raise_error(Addressable::URI::InvalidFileURIError)
      expect { described_class.file_uri_to_path("file:///a", :plan9) }.
        to raise_error(ArgumentError)
    end
  end

  describe "legacy .convert_path" do
    it "does not inspect the filesystem" do
      described_class.convert_path("/tmp/directory")
    end
  end
end
