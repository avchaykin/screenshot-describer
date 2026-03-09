class ScreenshotDescriber < Formula
  desc "Menubar service that watches a folder and processes new files"
  homepage "https://github.com/avchaykin/screenshot-describer"
  url "https://github.com/avchaykin/screenshot-describer/archive/refs/heads/main.tar.gz"
  version "0.1.0"
  sha256 :no_check
  license "MIT"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/screenshot-describer"
  end

  service do
    run [opt_bin/"screenshot-describer"]
    keep_alive true
    log_path var/"log/screenshot-describer.log"
    error_log_path var/"log/screenshot-describer.log"
  end

  test do
    assert_predicate bin/"screenshot-describer", :exist?
  end
end
