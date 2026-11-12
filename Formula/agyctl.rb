# Draft formula: move to the tap repo (iamdin/homebrew-tap, Formula/agyctl.rb).
class Agyctl < Formula
  desc "Run several Google Antigravity (agy) CLI accounts side by side"
  homepage "https://github.com/iamdin/agyctl"
  url "https://github.com/iamdin/agyctl/archive/refs/tags/vX.Y.Z.tar.gz" # TODO: real release
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # TODO: real sha256
  # license "..." # TODO: add a LICENSE to the repo, then declare it here

  def install
    # Scripts find their siblings (agy shim, runtime/) by resolving their own real path,
    # so keep bin/ and runtime/ together in libexec and expose only agyctl.
    libexec.install "bin", "runtime"
    bin.install_symlink libexec/"bin/agyctl"
  end

  test do
    assert_match "usage: agyctl", shell_output("#{bin}/agyctl --help")
    assert_path_exists libexec/"bin/agy"
    refute_path_exists bin/"agy"

    # `install` links the packaged shim into the data dir (no real agy is run).
    ENV["AGYCTL_DATA_DIR"] = testpath/"data"
    ENV["AGYCTL_REAL_HOME"] = testpath
    system bin/"agyctl", "install", "/usr/bin/true"
    assert_equal (libexec/"bin/agy").realpath, (testpath/"data/bin/agy").realpath
  end
end
