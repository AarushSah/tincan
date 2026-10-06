# Template for a Homebrew formula that installs tincan from a release archive. It isn't
# published yet: a tap needs a release with its archive attached.
#
# For each release, set `url` to the archive attached to the GitHub release and `sha256`
# to the value scripts/release.sh prints. The archive holds bin/ and share/ like an
# install prefix.
class Tincan < Formula
  desc "Messages, contacts and call history on a Mac, for you and your assistants"
  homepage "https://github.com/AarushSah/tincan"
  license "MIT"
  url "https://github.com/AarushSah/tincan/releases/download/v0.1.0/tincan-0.1.0-macos.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  depends_on macos: :sonoma

  def install
    bin.install "bin/tincan"
    man1.install "share/man/man1/tincan.1"
    zsh_completion.install "share/zsh/site-functions/_tincan"
    bash_completion.install "share/bash-completion/completions/tincan"
    fish_completion.install "share/fish/vendor_completions.d/tincan.fish"
    doc.install "share/doc/tincan/LICENSE", "share/doc/tincan/THIRD_PARTY_NOTICES.md"
  end

  def caveats
    <<~EOS
      tincan runs with the macOS permissions of the app you start it from, such as
      your terminal. See which app needs which permission, and grant them:
        tincan doctor --fix
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/tincan --version").strip
  end
end
