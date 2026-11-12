# Draft formula: move to the tap repo (iamdin/homebrew-tap, Formula/agyx.rb).
class Agyx < Formula
  desc "Run several Google Antigravity (agy) CLI profiles side by side"
  homepage "https://github.com/iamdin/agyx"
  url "https://github.com/iamdin/agyx/archive/refs/tags/vX.Y.Z.tar.gz" # TODO: real release
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # TODO: real sha256
  # license "..." # TODO: add a LICENSE to the repo, then declare it here

  def install
    # Scripts find their siblings (agy shim, runtime/) by resolving their own real path,
    # so keep bin/ and runtime/ together in libexec and expose only agyx.
    libexec.install "bin", "runtime"
    bin.install_symlink libexec/"bin/agyx"
  end

  test do
    # misuse of a management subcommand prints the usage and exits 2
    assert_match "usage: agyx", shell_output("#{bin}/agyx profile list extra 2>&1", 2)
    assert_path_exists libexec/"bin/agy"
    refute_path_exists bin/"agy"

    # `setup` only records the real agy; `shim`/`unshim` toggle the optional bare agy
    # takeover (no real agy is run).
    ENV["AGYX_DATA_DIR"] = testpath/"data"
    ENV["AGYX_REAL_HOME"] = testpath
    system bin/"agyx", "setup", "/usr/bin/true"
    assert_equal Pathname("/usr/bin/true").realpath, (testpath/"data/real-agy").realpath
    refute_path_exists testpath/"data/bin/agy"
    # anything that is not an agyx subcommand launches agy via the shim
    (testpath/"data/profiles/work/home").mkpath
    system bin/"agyx", "--profile", "work"
    system bin/"agyx", "shim"
    assert_equal (libexec/"bin/agy").realpath, (testpath/"data/bin/agy").realpath
    system bin/"agyx", "unshim"
    refute_path_exists testpath/"data/bin/agy"
  end
end
