#!/usr/bin/env python3
"""Run the ⌘D split's working-directory rules against the real sources:
python3 Tests/SplitWorkingDirectoryTests.py

Two pieces of production text are compiled into one harness: AppModel's
split cwd dataflow and HerdrService's `shellStartPrelude` (how that path reaches /bin/sh).
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model_source = (root / "Sources/GooseAgent/AppModel.swift").read_text()
service_source = (root / "Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift").read_text()

start = service_source.index("    static func shellStartPrelude(workingDirectory: String?) -> String {")
end = service_source.index("\n    }", start) + len("\n    }")
prelude = service_source[start:end]

# Wiring: the transport has to be handed the value, and the split is the only
# caller that has one — a standalone shell keeps the login directory.
assert "shellStartPrelude(workingDirectory: workingDirectory)" in service_source, (
    "the local command must build its startup directory through shellStartPrelude"
)
assert "cwd: shell.workingDirectory" in (
    root / "Sources/GooseAgent/ContentView.swift"
).read_text(), "each stable split leaf must pass its own startup cwd"
assert "process.currentWorkingDirectory" in model_source
assert "?? splitShells.first" in model_source, "unmounted new leaves inherit the startup cwd"
assert "terminalCommand(workingDirectory: workingDirectory)" in (
    root / "Sources/GooseAgent/TerminalView.swift"
).read_text(), "ShellTerminalView must forward its workingDirectory to the command"

harness = r'''
import Foundation

struct HerdrService {
''' + prelude + r'''
}

@main struct Check {
    static func main() {
        // No cwd produces exactly the command that shipped before this existed.
        assert(HerdrService.shellStartPrelude(workingDirectory: nil) == "cd \"$HOME\"")
        assert(HerdrService.shellStartPrelude(workingDirectory: "") == "cd \"$HOME\"")

        // Spaces and CJK stay one literal argument.
        assert(
            HerdrService.shellStartPrelude(workingDirectory: "/Users/a b/项目")
                == "cd '/Users/a b/项目' 2>/dev/null || cd \"$HOME\""
        )
        // A quote cannot end the argument early; a substitution cannot run.
        assert(
            HerdrService.shellStartPrelude(workingDirectory: "/tmp/a'b")
                == "cd '/tmp/a'\\''b' 2>/dev/null || cd \"$HOME\""
        )
        assert(
            HerdrService.shellStartPrelude(workingDirectory: "/tmp/$(id)`whoami`;rm -rf x")
                == "cd '/tmp/$(id)`whoami`;rm -rf x' 2>/dev/null || cd \"$HOME\""
        )
        // A directory deleted since it was reported still leaves a shell.
        assert(
            HerdrService.shellStartPrelude(workingDirectory: "/gone")
                == "cd '/gone' 2>/dev/null || cd \"$HOME\""
        )
        print("PASS: split startup cwd is safely quoted with HOME fallback")
        if CommandLine.arguments.count > 1 {
            print("PRELUDE:" + HerdrService.shellStartPrelude(workingDirectory: CommandLine.arguments[1]))
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="split-cwd-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    def shell_lands_in(source_path, cwd="/"):
        """The prelude the binary builds for `source_path`, run by a real /bin/sh."""
        prelude = subprocess.run(
            [str(binary), source_path], capture_output=True, text=True, check=True
        ).stdout.strip().splitlines()[-1].removeprefix("PRELUDE:")
        pwd = subprocess.run(
            ["/bin/sh", "-c", prelude + "; pwd"],
            capture_output=True, text=True, cwd=cwd, env={"HOME": str(Path.home())},
        )
        assert pwd.returncode == 0, pwd.stderr
        return Path(pwd.stdout.strip()).resolve()

    # The point of the prelude: the shell really does start in that directory,
    # with spaces, CJK and an apostrophe in the name all surviving the trip.
    awkward = directory / "项目 it's"
    awkward.mkdir()
    assert shell_lands_in(str(awkward)) == awkward.resolve()

    # A hostile path is one literal argument: nothing in it is executed, and the
    # shell falls back to $HOME because that directory does not exist.
    side_effect = directory / "PWNED"
    assert shell_lands_in(f"{directory}/$(touch {side_effect})`touch {side_effect}`") \
        == Path.home().resolve()
    assert not side_effect.exists(), "the path must never reach the shell as code"

    # Deleted since it was reported: still a shell, in $HOME.
    assert shell_lands_in(str(directory / "gone")) == Path.home().resolve()
    print("PASS: the local shell starts in the inherited directory or in $HOME")
