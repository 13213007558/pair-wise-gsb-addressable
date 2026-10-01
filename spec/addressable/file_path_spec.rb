# frozen_string_literal: true

require 'spec_helper'

require 'addressable/uri'

# Cross-platform string fixtures for RFC 8089 file URI conversion. These
# run identically no matter which platform the test suite executes on,
# because Addressable::URI.path_to_uri and Addressable::URI.uri_to_path
# take an explicit platform and never consult the local filesystem.
describe Addressable::URI, "file path conversion" do
  POSIX_FIXTURES = [
    ["/simple/path", "file:///simple/path"],
    ["/with space/and%percent", "file:///with%20space/and%25percent"],
    ["/unicode/文件/naïve", "file:///unicode/%E6%96%87%E4%BB%B6/na%C3%AFve"],
    ["/trailing/", "file:///trailing/"],
    ["/trailing space /dot./...", "file:///trailing%20space%20/dot./..."],
    ["/a/b/../c/./d", "file:///a/b/../c/./d"],
    ["/", "file:///"],
  ].freeze

  WINDOWS_FIXTURES = [
    ["C:\\windows\\foo.txt", "file:///C:/windows/foo.txt"],
    [
      "c:\\windows\\My Documents 100%20\\foo.txt",
      "file:///c:/windows/My%20Documents%20100%2520/foo.txt"
    ],
    ["D:\\unicode\\文件.txt", "file:///D:/unicode/%E6%96%87%E4%BB%B6.txt"],
    ["E:\\trailing\\", "file:///E:/trailing/"],
    ["C:\\", "file:///C:/"],
    ["\\\\server\\share\\dir\\file.txt", "file://server/share/dir/file.txt"],
    ["\\\\server\\share", "file://server/share"],
    ["\\\\localhost\\share\\d i r", "file://localhost/share/d%20i%20r"],
  ].freeze

  before do
    # The conversion must be pure string processing: any attempt to
    # probe the local filesystem fails the test.
    allow(File).to receive(:exist?).and_raise(
      "conversion must not access the filesystem"
    )
    allow(File).to receive(:stat).and_raise(
      "conversion must not access the filesystem"
    )
  end

  describe ".path_to_uri" do
    POSIX_FIXTURES.each do |path, uri|
      it "converts posix path #{path.inspect} to #{uri.inspect}" do
        expect(
          Addressable::URI.path_to_uri(path, platform: :posix).to_s
        ).to eq(uri)
      end
    end

    WINDOWS_FIXTURES.each do |path, uri|
      it "converts windows path #{path.inspect} to #{uri.inspect}" do
        expect(
          Addressable::URI.path_to_uri(path, platform: :windows).to_s
        ).to eq(uri)
      end
    end

    it "accepts forward slashes in windows paths" do
      expect(
        Addressable::URI.path_to_uri(
          "C:/windows/foo.txt", platform: :windows
        ).to_s
      ).to eq("file:///C:/windows/foo.txt")
      expect(
        Addressable::URI.path_to_uri(
          "//server/share/dir", platform: :windows
        ).to_s
      ).to eq("file://server/share/dir")
    end

    it "accepts string platform names" do
      expect(
        Addressable::URI.path_to_uri("/tmp/x", platform: "posix").to_s
      ).to eq("file:///tmp/x")
    end

    it "resolves relative posix paths against an absolute base" do
      expect(
        Addressable::URI.path_to_uri(
          "rel/file.txt", platform: :posix, base: "/base/dir"
        ).to_s
      ).to eq("file:///base/dir/rel/file.txt")
      expect(
        Addressable::URI.path_to_uri(
          "rel/file.txt", platform: :posix, base: "/base/dir/"
        ).to_s
      ).to eq("file:///base/dir/rel/file.txt")
      expect(
        Addressable::URI.path_to_uri(
          "rel/file.txt", platform: :posix, base: "/"
        ).to_s
      ).to eq("file:///rel/file.txt")
    end

    it "resolves relative windows paths against an absolute base" do
      expect(
        Addressable::URI.path_to_uri(
          "docs\\f.txt", platform: :windows, base: "C:\\base"
        ).to_s
      ).to eq("file:///C:/base/docs/f.txt")
      expect(
        Addressable::URI.path_to_uri(
          "docs\\f.txt", platform: :windows, base: "\\\\server\\share"
        ).to_s
      ).to eq("file://server/share/docs/f.txt")
    end

    it "rejects relative paths without a base" do
      expect do
        Addressable::URI.path_to_uri("rel/file.txt", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri("rel\\file.txt", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects a base that is not absolute for the same platform" do
      expect do
        Addressable::URI.path_to_uri(
          "rel", platform: :posix, base: "not/absolute"
        )
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri(
          "rel", platform: :windows, base: "notabsolute"
        )
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri(
          "rel", platform: :windows, base: "C:relative"
        )
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects paths containing NUL bytes" do
      expect do
        Addressable::URI.path_to_uri("/a\0b", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri("C:\\a\0b", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects windows device paths" do
      expect do
        Addressable::URI.path_to_uri("\\\\?\\C:\\foo", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri("\\\\.\\pipe\\x", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri(
          "\\\\?\\UNC\\server\\share", platform: :windows
        )
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects drive-relative and rooted drive-relative paths" do
      expect do
        Addressable::URI.path_to_uri("C:foo", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri("C:", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri("\\foo", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects UNC paths without a host or share" do
      expect do
        Addressable::URI.path_to_uri("\\\\server", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.path_to_uri("\\\\\\share", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects unknown platforms" do
      expect do
        Addressable::URI.path_to_uri("/x", platform: :plan9)
      end.to raise_error(ArgumentError)
    end

    it "rejects non-string paths" do
      expect do
        Addressable::URI.path_to_uri(42, platform: :posix)
      end.to raise_error(TypeError)
    end
  end

  describe ".uri_to_path" do
    POSIX_FIXTURES.each do |path, uri|
      it "converts #{uri.inspect} to posix path #{path.inspect}" do
        expect(
          Addressable::URI.uri_to_path(uri, platform: :posix)
        ).to eq(path)
      end
    end

    WINDOWS_FIXTURES.each do |path, uri|
      it "converts #{uri.inspect} to windows path #{path.inspect}" do
        expect(
          Addressable::URI.uri_to_path(uri, platform: :windows)
        ).to eq(path)
      end
    end

    it "accepts Addressable::URI objects" do
      uri = Addressable::URI.parse("file:///tmp/a%20file.txt")
      expect(
        Addressable::URI.uri_to_path(uri, platform: :posix)
      ).to eq("/tmp/a file.txt")
    end

    it "treats a localhost host as local on posix" do
      expect(
        Addressable::URI.uri_to_path(
          "file://localhost/etc/fstab", platform: :posix
        )
      ).to eq("/etc/fstab")
    end

    it "decodes percent-encoded backslashes on posix" do
      expect(
        Addressable::URI.uri_to_path("file:///a%5Cb", platform: :posix)
      ).to eq("/a\\b")
    end

    it "rejects non-file schemes" do
      expect do
        Addressable::URI.uri_to_path("http://example.com/", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects query and fragment components" do
      expect do
        Addressable::URI.uri_to_path("file:///a?x=1", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.uri_to_path("file:///a#frag", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects percent-encoded directory separators" do
      expect do
        Addressable::URI.uri_to_path("file:///a%2Fb", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.uri_to_path("file:///C:/a%2Fb", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.uri_to_path("file:///C:/a%5Cb", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects percent-encoded NUL bytes" do
      expect do
        Addressable::URI.uri_to_path("file:///a%00b", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects remote hosts on posix" do
      expect do
        Addressable::URI.uri_to_path("file://server/share", platform: :posix)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects windows URIs without a drive letter or share name" do
      expect do
        Addressable::URI.uri_to_path("file:///nohost/", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
      expect do
        Addressable::URI.uri_to_path("file://server/", platform: :windows)
      end.to raise_error(Addressable::URI::InvalidPathError)
    end

    it "rejects unknown platforms" do
      expect do
        Addressable::URI.uri_to_path("file:///x", platform: :plan9)
      end.to raise_error(ArgumentError)
    end
  end

  describe "round trips" do
    POSIX_FIXTURES.each do |path, uri|
      it "round-trips posix path #{path.inspect}" do
        expect(
          Addressable::URI.uri_to_path(
            Addressable::URI.path_to_uri(path, platform: :posix),
            platform: :posix
          )
        ).to eq(path)
        expect(
          Addressable::URI.path_to_uri(
            Addressable::URI.uri_to_path(uri, platform: :posix),
            platform: :posix
          ).to_s
        ).to eq(uri)
      end
    end

    WINDOWS_FIXTURES.each do |path, uri|
      it "round-trips windows path #{path.inspect}" do
        expect(
          Addressable::URI.uri_to_path(
            Addressable::URI.path_to_uri(path, platform: :windows),
            platform: :windows
          )
        ).to eq(path)
        expect(
          Addressable::URI.path_to_uri(
            Addressable::URI.uri_to_path(uri, platform: :windows),
            platform: :windows
          ).to_s
        ).to eq(uri)
      end
    end
  end
end
