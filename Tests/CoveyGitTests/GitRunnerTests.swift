import XCTest
@testable import CoveyGit

final class GitRunnerTests: XCTestCase {
    private var repo: TestRepo!

    override func setUpWithError() throws { repo = try TestRepo() }
    override func tearDown() { repo.remove() }

    func testRunReturnsTrimmedStdout() throws {
        XCTAssertEqual(try GitRunner.run(in: repo.path, ["branch", "--show-current"]), "main")
    }

    func testNonZeroExitThrowsFailedWithStderr() {
        XCTAssertThrowsError(try GitRunner.run(in: repo.path, ["rev-parse", "--verify", "nope"])) { error in
            let gitError = error as? GitError
            guard case .failed(let status)? = gitError?.kind else {
                return XCTFail("expected .failed, got \(error)")
            }
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(gitError!.description.isEmpty)
        }
    }

    func testEmptyStderrFallsBackToCommandInMessage() {
        // `diff --quiet` exits 1 with no output when there is a difference.
        try? repo.write("a.txt", "x")
        XCTAssertThrowsError(try GitRunner.run(in: repo.path, ["diff", "--quiet", "--no-index", "/dev/null", "a.txt"])) { error in
            XCTAssertEqual("\(error)", "git diff --quiet --no-index /dev/null a.txt failed")
        }
    }

    func testExecuteReportsStatusWithoutThrowing() throws {
        try repo.write("a.txt", "hello\n")
        let out = try GitRunner.execute(in: repo.path, ["diff", "--no-index", "--", "/dev/null", "a.txt"],
                                        readOnly: true)
        XCTAssertEqual(out.status, 1)
        XCTAssertTrue(out.stdout.contains("+hello"))
    }

    func testEnvironmentPinsLocaleAndOptionalLocks() {
        XCTAssertEqual(GitRunner.environment(readOnly: true)["LC_ALL"], "C")
        XCTAssertEqual(GitRunner.environment(readOnly: true)["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertNil(GitRunner.environment(readOnly: false)["GIT_OPTIONAL_LOCKS"])
    }

    func testLargeStderrDoesNotDeadlock() throws {
        // 300 KB on stderr overflows the ~64 KB pipe buffer: a reader that
        // drains stdout first blocks forever here.
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done"],
            environment: [:], timeout: 10, outputLimit: 1 << 20)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
        XCTAssertEqual(result.stderr.count, 300_000)
    }

    func testTimeoutTerminatesTheChild() {
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 5"],
            environment: [:], timeout: 0.3, outputLimit: 1 << 20)) { error in
            XCTAssertEqual(error as? ProcessFailure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testOutputLimitStopsTheChild() {
        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "head -c 100000 /dev/zero"],
            environment: [:], timeout: 10, outputLimit: 1000)) { error in
            XCTAssertEqual(error as? ProcessFailure, .outputTooLarge)
        }
    }

    /// The output cap trips once, so the runner terminates the child once.
    func testOutputCapTripsExactlyOnce() {
        let buffers = OutputBuffers(limit: 10)
        XCTAssertFalse(buffers.append(Data(count: 6), stdout: true))
        XCTAssertTrue(buffers.append(Data(count: 6), stdout: false))
        XCTAssertFalse(buffers.append(Data(count: 6), stdout: true))
        XCTAssertFalse(buffers.append(Data(count: 6), stdout: false))
        XCTAssertTrue(buffers.overflowed)
    }

    /// EOF-leave and detach-leave are mutually exclusive per pipe, so the drain
    /// group is left exactly once for each `enter()`.
    func testDrainGroupLeavesExactlyOncePerPipe() {
        let buffers = OutputBuffers(limit: 10)
        XCTAssertTrue(buffers.finish(stdout: true))      // stdout reached EOF: its leave is the handler's
        XCTAssertFalse(buffers.finish(stdout: true))     // a repeated EOF never leaves twice
        XCTAssertEqual(buffers.abandonOpenPipes(), 1)    // only stderr is still owed
        XCTAssertFalse(buffers.finish(stdout: false))    // a handler still in flight loses to detach
        XCTAssertEqual(buffers.abandonOpenPipes(), 0)    // detach is idempotent

        let untouched = OutputBuffers(limit: 10)
        XCTAssertEqual(untouched.abandonOpenPipes(), 2)  // timeout / launch-failure path
    }

    func testRunnerMapsTimeoutToGitError() throws {
        XCTAssertThrowsError(try GitRunner.execute(
            in: repo.path, ["-c", "alias.slow=!sleep 5", "slow"], readOnly: true, timeout: 0.3)) { error in
            XCTAssertEqual((error as? GitError)?.kind, .timedOut)
        }
    }
}
