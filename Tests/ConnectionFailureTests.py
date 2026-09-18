#!/usr/bin/env python3
"""Connection failure copy and Tailscale URL extraction: python3 Tests/ConnectionFailureTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("enum ConnectionFailureFormatting {")
end = source.index("\n/// Agent kinds offered by the picker.", start)
block = source[start:end]

harness = r'''
import Foundation

''' + block + r'''

@main struct Check {
    static func main() {
        let reason = """
        # Tailscale SSH requires an additional checkoff.
        # To authenticate, visit: https://login.tailscale.com/a/l12b1fd4d337822
        """
        assert(ConnectionFailureFormatting.isTailscaleCheckoff(reason))
        assert(
            ConnectionFailureFormatting.tailscaleAuthenticationURL(in: reason)
                == "https://login.tailscale.com/a/l12b1fd4d337822"
        )
        assert(!ConnectionFailureFormatting.isTailscaleCheckoff("permission denied (publickey)"))
        assert(ConnectionFailureFormatting.tailscaleAuthenticationURL(in: "no url") == nil)
        print("PASS: Tailscale checkoff copy extracts the verification URL")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="connection-failure-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
