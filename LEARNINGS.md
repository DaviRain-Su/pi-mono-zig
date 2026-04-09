# Zig 0.16 开发学习笔记

## 1. std.Io 架构与 async 模型

### 核心结论
- `std.Io` 是 Zig 0.16 全新的统一运行时，合并了旧 `std.io` + `std.event` 的能力
- `init.io` 在 Linux 多线程 build 下**永远是 `std.Io.Threaded`**，一个工作窃取线程池
- Zig 0.16 的 `async/await` **不是语言级特性**，而是 `std.Io` 运行时的线程池调度：
  - `Io.async(io, func, args)` → 把函数提交到线程池
  - `Future.await(io)` → **阻塞当前线程**等待结果
  - 没有 `suspend`/`resume` 状态机

### POSIX I/O 现状
- 在 Linux 上，`std.Io.Threaded` 的网络和文件 I/O **底层仍是同步阻塞 syscall**：
  - `netConnectIpPosix` 直接调 `connect()`
  - `fileWriteStreaming` 直接调 `writev()`
  - `sleep` 直接调 `clock_nanosleep()`
- **尚未集成 io_uring / epoll / kqueue 纯异步 I/O**
- 目前的并发效果来自“多个 OS worker 线程各自阻塞等待 I/O”

### 对项目的影响
- 在 `std.Thread.spawn` 的 detach 线程里使用 `std.http.Client` 是**安全的**
- 底层是阻塞 syscall，各线程独立，没有额外的事件循环依赖
- 但 `init.io` 不适合在 detach 线程里执行需要 `Io.Threaded` 调度循环的任务（如 `Future.await` 与 Io 事件循环深度耦合的场景）

---

## 2. EventStream 的同步原语陷阱

### 问题现象
- `test-ai` 在 `client.fetch` 成功返回后，`es.next()` 仍然卡住 300 秒

### 根因
- `streamOpenAICompletions` 里创建了一个**栈上**的 `EventStream`，并通过 `std.Thread.spawn` 把 `&es` 传给线程
- 但函数返回时把 `EventStream` **按值复制**给了 caller
- `std.Thread.Mutex` / `std.Thread.Condition` 存储在 struct 内部，地址变了
- thread 里的 `cond.broadcast()` 发到旧地址，main 线程在新地址的 `cond.wait()` 永远收不到唤醒

### 修复方案
把 `EventStream` 内部的所有同步状态改为**堆上分配**，struct 本身只保存指针：

```zig
const Inner = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(Event) = .empty,
    done: bool = false,
    ...
};
inner: *Inner,
```

无论 `EventStream` struct 被复制多少次，`inner` 指向的 `Mutex`/`Condition` 地址不变，广播与等待就能匹配。

---

## 3. Zig 0.16 API 变更记录

### ArrayList
- `std.ArrayList(T)` → **unmanaged**（没有内嵌 allocator）
- `std.array_list.Managed(T)` → **managed** 版本，用于 `std.json.Value.array`
- managed 的 `append()` 不需要传 allocator，用 `.init(gpa)` 初始化

### JSON
- `std.json.stringifyAlloc` 已移除
- 替代方案：`std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(value, .{})})`
- `std.json.ObjectMap` 的 `remove()` 改名为 `swapRemove()`
- `std.json.Value` 没有 `.deinit()`，内存随分配器释放

### HTTP Client
- `client.open()` → 改用 `client.request()` 或更高层的 `client.fetch()`
- `client.fetch()` 是 Zig 0.16 推荐的一次性请求 API：
  ```zig
  var body_alloc = std.Io.Writer.Allocating.init(gpa);
  defer body_alloc.deinit();
  const result = try client.fetch(.{
      .location = .{ .uri = uri },
      .method = .POST,
      .payload = payload,
      .response_writer = &body_alloc.writer,
  });
  const body = try body_alloc.toOwnedSlice();
  ```

### File Writer / flush
- `std.Io.File.stdout().writer(init.io, &buf)` 返回的 writer 有 buffering
- 必须显式调用 `writer.flush()` 才能让输出真正到达终端

### 时间 / sleep
- `std.time.milliTimestamp()` / `std.time.sleep()` 已移除
- 时钟读取：`std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME)`
- 线程睡眠：`std.Thread.sleep` 也移除，可用 `std.Io.sleep(io, duration, clock)` 或 `posix.nanosleep`

### JSON in HTTP SSE streams (critical)
- **Never** call `std.json.parseFromSlice` + `defer parsed.deinit()` inside an SSE loop.
  The `Parsed` wrapper frees the JSON tree; string slices extracted from it become dangling
  pointers if they are pushed into an `EventStream` queue.
- **Always use the shared helpers**:
  ```zig
  const shared = @import("shared");
  const data = shared.http.parseSseData(line) orelse continue;
  const chunk = shared.http.parseSseJsonLine(data, arena_gpa) catch continue;
  // chunk is a std.json.Value whose lifetime equals the arena
  ```
- `parseSseData` also normalizes both `data: {...}` and `data:{...}` (no space after colon).

### zig.testing.expectEqual with optional floats
- `try std.testing.expectEqual(@as(?f32, null), value.temperature)` is required;
  inference from `?u32` will produce a compile error.

---

## 4. 后续开发建议

### 并发策略
- 短生命周期 HTTP 请求：继续用 `std.Thread.spawn` + detach，简单直接
- 如果需要更深度的 Io 集成（任务取消、统一调度）：改用 `std.Io.concurrent()` / `std.Io.async()`
- **永远不要把包含 `Mutex`/`Condition` 的 struct 按值传递到别的线程**

### 新增 provider 的强制规范
1. SSE 解析：必须复用 `shared.http.parseSseData` / `shared.http.parseSseJsonLine`。
2. `streamSimple*` 函数：必须通过 `ai.simple_options.buildBaseOptions(model, options, api_key)` 生成 `StreamOptions`。
   禁止在 `streamSimple*` 中直接读取 `options.base.*` 字段。
3. EventStream 中的字符串切片：必须指向比 `EventStream` 生命周期更长的内存（通常是 `page_allocator` 或线程 arena）。

### Agent Loop 实现要点
- 原始 TS 的 `agentLoop` 是 async/await 驱动
- Zig 版本需改为：**thread 中顺序执行 fetch + tool 调用，通过 `EventStream` push 事件回主线程**
- 工具调用支持 `sequential` 和 `parallel` 两种模式：
  - sequential：循环逐个执行
  - parallel：`std.Thread.spawn` 多个子线程 + `join()` 等待
