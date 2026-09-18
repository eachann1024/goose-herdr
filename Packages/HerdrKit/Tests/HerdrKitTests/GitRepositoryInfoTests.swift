import XCTest
@testable import HerdrKit

final class GitRepositoryInfoTests: XCTestCase {
    func testParseDistinguishesLinkedWorktreeAndBranch() throws {
        let output = "/Users/me/project/wt\n/Users/me/project/.git/worktrees/wt\n/Users/me/project/.git\nfeature/ui\n"
        let info = try XCTUnwrap(HerdrService.GitRepositoryInfo.parse(output))
        XCTAssertEqual(info.repositoryName, "project")
        XCTAssertEqual(info.branch, "feature/ui")
        XCTAssertTrue(info.isWorktree)
    }

    func testParseRejectsMissingGitMetadata() {
        XCTAssertNil(HerdrService.GitRepositoryInfo.parse("not-a-git-directory\n"))
    }
}
