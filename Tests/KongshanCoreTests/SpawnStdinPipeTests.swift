import Darwin
import Foundation
import HelperProtocol
import XCTest

/// helper 用 `pipe()` + `posix_spawn` 把配置从 stdin 喂给 sing-box。这里锁死一个**必须遵守的前提**：
/// 管道两端都要置 `FD_CLOEXEC`。
///
/// `posix_spawn` 会把所有未标记 CLOEXEC 的 fd 原样继承给子进程。写端一旦被子进程继承，
/// 它就自己握着自己 stdin 管道的写端，**父进程写完关闭也永远等不到 EOF**：
/// sing-box 会一直阻塞在读配置——进程活着、不监听端口、日志 0 字节，
/// App 侧表现为 "sing-box 控制接口未就绪：Could not connect to the server."。
final class SpawnStdinPipeTests: XCTestCase {
    /// 用 `/bin/cat` 当替身：它读完 stdin 才退出，正好用来判定子进程有没有收到 EOF。
    /// - Parameter closeOnExec: 是否给管道两端置 FD_CLOEXEC。
    /// - Returns: 子进程是否在超时前退出（收到 EOF）。
    private func childSeesEOF(closeOnExec: Bool, timeout: TimeInterval = 3) -> Bool {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return false }
        let readEnd = fds[0]
        let writeEnd = fds[1]
        if closeOnExec {
            _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        // 子进程输出丢弃，避免污染测试日志。
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let path = "/bin/cat"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let spawned = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&pid, path, &actions, nil, buffer.baseAddress, nil)
        }
        close(readEnd)
        guard spawned == 0, pid > 0 else { close(writeEnd); return false }

        // 写入一点数据后关掉写端：若子进程没继承写端，它此刻应读到 EOF 并退出。
        let payload = Array("{}\n".utf8)
        _ = payload.withUnsafeBufferPointer { write(writeEnd, $0.baseAddress, $0.count) }
        close(writeEnd)

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            usleep(50_000)
        }
        // 超时说明子进程还卡在读 stdin：清理掉，别留残兵。
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        return false
    }

    /// 置了 CLOEXEC：子进程读到 EOF 正常退出——这是 helper 必须保持的行为。
    func testChildReachesEOFWhenPipeIsCloseOnExec() {
        XCTAssertTrue(
            childSeesEOF(closeOnExec: true),
            "置了 FD_CLOEXEC 仍收不到 EOF，说明喂配置这条路彻底坏了"
        )
    }

    /// 反向证明：不置 CLOEXEC 时子进程继承了写端，**永远等不到 EOF**。
    /// 这正是"内核活着但不启动、日志 0 字节、控制接口连不上"的机制。
    func testChildNeverSeesEOFWithoutCloseOnExec() {
        XCTAssertFalse(
            childSeesEOF(closeOnExec: false),
            "不置 CLOEXEC 居然也能收到 EOF？该结论过时了，需重新评估 helper 的 spawn 方式"
        )
    }
}

/// 真进程验证信号升级：起一个**故意忽略 SIGINT** 的子进程（模拟睡眠唤醒后假死的内核），
/// 确认升级策略能真的把它杀掉。只发 SIGINT 的旧写法在这里必然失败。
final class KernelTerminationLiveTests: XCTestCase {
    func testTerminatesProcessThatIgnoresSIGINT() throws {
        var pid: pid_t = 0
        let path = "/bin/sh"
        // trap "" INT：忽略 SIGINT；随后长睡。
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(path), strdup("-c"), strdup("trap '' INT; sleep 120"), nil
        ]
        defer { argv.forEach { free($0) } }
        let spawned = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&pid, path, nil, nil, buffer.baseAddress, nil)
        }
        try XCTSkipUnless(spawned == 0 && pid > 0, "无法 spawn 测试进程")
        // 等 shell 真正装好 trap。
        usleep(300_000)

        // 先确认 SIGINT 单发确实杀不掉它（这就是旧写法的问题）。
        kill(pid, SIGINT)
        usleep(300_000)
        XCTAssertEqual(kill(pid, 0), 0, "子进程没有忽略 SIGINT，测试前提不成立")

        var sent: [Int32] = []
        let stopped = HelperKernelTermination.terminate(
            pid: pid,
            isAlive: { pid in
                // 与 helper 同款：先收尸，否则僵尸会被当成"还活着"。
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { return false }
                return kill(pid, 0) == 0
            },
            send: { target, signalNumber in sent.append(signalNumber); kill(target, signalNumber) },
            waitStep: { usleep(50_000) },
            stepsPerSignal: 10
        )
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
        XCTAssertTrue(stopped, "升级策略没能杀掉假死进程")
        XCTAssertTrue(sent.contains(SIGTERM) || sent.contains(SIGKILL), "只发了 SIGINT，没有升级")
        XCTAssertNotEqual(kill(pid, 0), 0, "进程仍然活着")
    }
}
