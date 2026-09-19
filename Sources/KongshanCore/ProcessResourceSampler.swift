import Darwin
import Foundation

/// 本进程某一时刻的资源快照。
///
/// `userSeconds` 与 `systemSeconds` 分开保留**不是为了好看**：它是归因异常 CPU 的第一判据。
/// 2026-08-18 的复盘里，App 累计 846 分钟 user 对 52 分钟 system（约 16:1），这一个比值就
/// 排除了「relay 转发把 CPU 吃掉了」——转发是 read/write 密集，system 占比必然高得多；
/// 16:1 指向的是纯计算（视图求值、解码、解析）。只记一个合计 CPU 就丢掉了这个判据。
public struct ProcessResourceSample: Equatable, Sendable {
    public let capturedAt: Date
    public let userSeconds: Double
    public let systemSeconds: Double
    public let residentBytes: UInt64
    public let threadCount: Int
    /// 调用线程（自诊断跑在主线程上，所以就是主线程）的累计 CPU。
    ///
    /// 这是分辨「界面在烧」与「后台在烧」的判据，2026-08-18 的复盘正是靠它定位的：
    /// 进程累计 1070 分钟，主线程只有 8.5 秒 ⇒ 与 SwiftUI 渲染无关，是后台并发线程在做重计算。
    /// 没有这一项，下一次仍然只能靠人工 `ps -M` 去比对。
    public let mainThreadSeconds: Double

    public var totalSeconds: Double { userSeconds + systemSeconds }

    public init(
        capturedAt: Date,
        userSeconds: Double,
        systemSeconds: Double,
        residentBytes: UInt64,
        threadCount: Int,
        mainThreadSeconds: Double = 0
    ) {
        self.capturedAt = capturedAt
        self.userSeconds = userSeconds
        self.systemSeconds = systemSeconds
        self.residentBytes = residentBytes
        self.threadCount = threadCount
        self.mainThreadSeconds = mainThreadSeconds
    }
}

/// 读取本进程的 CPU / 内存 / 线程数。
///
/// CPU 用 `getrusage(RUSAGE_SELF)`：它是 POSIX 的，返回**本进程全部线程**的累计用时，
/// 且**不含已回收的子进程**（`RUSAGE_CHILDREN` 才是那个）。这一点在本轮诊断里实测确认过，
/// 所以内核子进程的开销不会混进 App 自己的读数。
///
/// RSS 不能用 `getrusage` 的 `ru_maxrss`——那是历史峰值，只增不减，看不出回落；
/// 要当前值必须问 mach 的 `MACH_TASK_BASIC_INFO`。
public enum ProcessResourceSampler {
    public static func current(now: Date = Date()) -> ProcessResourceSample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }

        return ProcessResourceSample(
            capturedAt: now,
            userSeconds: seconds(from: usage.ru_utime),
            systemSeconds: seconds(from: usage.ru_stime),
            residentBytes: residentBytes() ?? 0,
            threadCount: threadCount() ?? 0,
            mainThreadSeconds: callingThreadSeconds() ?? 0
        )
    }

    /// 调用线程的累计 user+system CPU。`mach_thread_self()` 返回的是一个需要显式
    /// `mach_port_deallocate` 的发送权，漏掉会稳定泄漏 mach port。
    private static func callingThreadSeconds() -> Double? {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }

        var info = thread_basic_info()
        // `THREAD_BASIC_INFO_COUNT` 是个 C 宏，Swift 导不进来，按定义自己算。
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    private static func seconds(from value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.resident_size
    }

    /// `task_threads` 交出**两种**要还的东西：数组本身的 vm，和数组里**每条线程的
    /// send right**。首版只还了前者——短期看不出来（同一线程的 right 合并进同一个
    /// 名字，端口表不涨，只涨引用计数），但每天 5,760 次采样会在 ~11 天后把 urefs
    /// 顶到溢出，`task_threads` 开始报错，线程数指标静默变 0；而 dispatch 线程池的
    /// 短命线程退出后，漏掉的 right 变成死名字在端口表里永久堆积。
    /// 诊断代码把被诊断的进程拖垮就本末倒置了，两种都必须逐一归还。
    private static func threadCount() -> Int? {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads else { return nil }
        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
            )
        }
        return Int(count)
    }
}
