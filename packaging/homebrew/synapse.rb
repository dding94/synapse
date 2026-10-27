# Homebrew formula 틀 — dding94/homebrew-tap 저장소의 Formula/synapse.rb로 쓴다.
# 릴리스마다 tools/package.sh가 만든 dist/synapse-<버전>.tar.gz를 GitHub 릴리스에 올리고, url의 버전과 그 파일의 sha256을 바꾼다.
class Synapse < Formula
  desc "Personal search and work-tidying app for macOS (Korean UI)"
  homepage "https://github.com/dding94/synapse"
  url "https://github.com/dding94/synapse/releases/download/v__VERSION__/synapse-__VERSION__.tar.gz"
  sha256 "__SHA256__"
  license "MIT"
  head "https://github.com/dding94/synapse.git", branch: "main"

  depends_on macos: :sonoma

  def install
    # 소스를 이 Mac에서 빌드한다(Xcode Command Line Tools의 swiftc). 앱은 prefix 안에 둔다.
    ENV["SYNAPSE_OUTPUTS"] = prefix.to_s
    system "bash", "./build.sh"
    bin.install "build/synapse-cli"
    bin.install_symlink prefix/"Synapse.app/Contents/MacOS/synapse-mcp"
  end

  def caveats
    <<~EOS
      앱을 응용 프로그램 폴더에 연결하려면:
        ln -sfn "#{opt_prefix}/Synapse.app" ~/Applications/Synapse.app
      열기: open ~/Applications/Synapse.app   (다음부터 단축키 ⌃⌥Space)
      Claude Code에서 Synapse 도구 쓰기(선택):
        claude mcp add --scope user synapse -- "#{opt_bin}/synapse-mcp"
    EOS
  end

  test do
    assert_predicate prefix/"Synapse.app/Contents/MacOS/Synapse", :executable?
    assert_match "사용법", shell_output("#{bin}/synapse-cli 2>&1", 0)
  end
end
