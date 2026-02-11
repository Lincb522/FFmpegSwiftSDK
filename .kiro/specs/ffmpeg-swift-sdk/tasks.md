# 实现计划：FFmpeg Swift SDK

## 概述

按照分层架构自底向上实现：先搭建 Swift Package 项目结构和 FFmpeg C 桥接层，然后实现核心引擎组件（解复用、解码、EQ、同步），最后实现公开 API 层并将所有组件串联起来。

## 任务

- [x] 1. 搭建项目结构与 FFmpeg C 桥接
  - [x] 1.1 创建 Swift Package 项目结构
    - 创建 `Package.swift`，定义 `CFFmpeg`（systemLibrary target）和 `FFmpegSwiftSDK`（Swift target）
    - 创建 `Sources/CFFmpeg/module.modulemap` 和 `Sources/CFFmpeg/shim.h`
    - 创建 `Sources/FFmpegSwiftSDK/` 目录结构
    - 创建 `Tests/FFmpegSwiftSDKTests/` 目录结构
    - 添加 SwiftCheck 依赖到 Package.swift
    - _Requirements: 1.1, 1.4_

  - [x] 1.2 实现 FFmpegError 枚举和错误码映射
    - 创建 `Sources/FFmpegSwiftSDK/Core/FFmpegError.swift`
    - 实现 FFmpegError 枚举，包含 connectionFailed、connectionTimeout、unsupportedFormat、decodingFailed、resourceAllocationFailed、networkDisconnected、unknown
    - 实现 `from(code:)` 静态方法，将 FFmpeg 负数错误码映射为枚举值
    - 实现 CustomStringConvertible，提供人类可读描述和原始错误码
    - _Requirements: 8.1, 8.2, 8.3_

  - [x] 1.3 编写 FFmpegError 错误码映射属性测试
    - **Property 10: 错误码映射完整性**
    - 使用 SwiftCheck 生成随机负数 Int32，验证 from(code:) 返回有效实例、description 非空、ffmpegCode 等于输入
    - 最少 100 次迭代
    - **Validates: Requirements 7.4, 8.2, 8.3**

- [x] 2. 实现 EQ 滤波器核心
  - [x] 2.1 实现数据模型
    - 创建 `Sources/FFmpegSwiftSDK/Models/AudioBuffer.swift`，定义 AudioBuffer 结构体
    - 创建 `Sources/FFmpegSwiftSDK/Models/EQBand.swift`，定义 EQBand 枚举和 EQBandGain 结构体
    - 实现 EQBandGain.clamped() 钳位函数
    - _Requirements: 5.1, 5.3_

  - [x] 2.2 编写增益钳位属性测试
    - **Property 4: 增益钳位正确性**
    - 使用 SwiftCheck 生成任意 Float，验证 clamped 结果在 [-12, 12] 范围内，范围内值不变，范围外值等于边界
    - 最少 100 次迭代
    - **Validates: Requirements 5.3, 5.4**

  - [x] 2.3 实现 Biquad 滤波器和 EQFilter
    - 创建 `Sources/FFmpegSwiftSDK/Engine/EQFilter.swift`
    - 实现 Biquad peaking EQ 滤波器系数计算（基于 Audio EQ Cookbook）
    - 实现 process() 方法对 PCM 缓冲区应用三频段 EQ
    - 使用 NSLock 实现线程安全的增益参数读写
    - _Requirements: 5.1, 5.2, 5.5, 5.7_

  - [x] 2.4 编写零增益恒等变换属性测试
    - **Property 5: 零增益恒等变换**
    - 使用 SwiftCheck 生成随机 PCM 缓冲区，所有增益设为 0dB，验证输出与输入误差 < 1e-6
    - 最少 100 次迭代
    - **Validates: Requirements 5.5**

  - [x] 2.5 编写增益实时应用属性测试
    - **Property 6: 增益实时应用**
    - 使用 SwiftCheck 生成随机频段和增益值，验证设置后下一个缓冲区输出反映新增益
    - 最少 100 次迭代
    - **Validates: Requirements 5.2**

  - [x] 2.6 编写 EQ 线程安全属性测试
    - **Property 7: EQ 线程安全**
    - 使用 SwiftCheck 生成随机并发操作序列，在多线程环境下并发修改增益和处理音频，验证无崩溃且输出一致
    - 最少 100 次迭代
    - **Validates: Requirements 5.7**

- [x] 3. 检查点 - EQ 核心验证
  - 确保所有测试通过，如有问题请向用户确认。

- [x] 4. 实现 FFmpeg 封装与连接管理
  - [x] 4.1 实现 FFmpeg C 指针封装类
    - 创建 `Sources/FFmpegSwiftSDK/Bridge/FFmpegFormatContext.swift`
    - 封装 AVFormatContext 的分配、打开、关闭操作
    - 在 deinit 中保证 avformat_close_input 调用
    - 创建 `Sources/FFmpegSwiftSDK/Bridge/FFmpegCodecContext.swift`
    - 封装 AVCodecContext 的分配和释放
    - _Requirements: 1.2, 1.3, 7.1, 7.5_

  - [x] 4.2 实现 ConnectionManager
    - 创建 `Sources/FFmpegSwiftSDK/Engine/ConnectionManager.swift`
    - 实现 connect(url:) async throws 方法，支持 RTMP/HLS/RTSP
    - 实现 10 秒超时机制
    - 实现 disconnect() 方法释放资源
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.6_

  - [x] 4.3 编写无效 URL 错误处理属性测试
    - **Property 1: 无效 URL 错误处理**
    - 使用 SwiftCheck 生成随机无效 URL 字符串，验证 connect 抛出 FFmpegError
    - 最少 100 次迭代
    - **Validates: Requirements 2.4**

- [x] 5. 实现解复用与解码
  - [x] 5.1 实现 Demuxer
    - 创建 `Sources/FFmpegSwiftSDK/Engine/Demuxer.swift`
    - 实现 findStreams() 方法定位音频和视频流索引
    - 实现 readNextPacket() 方法循环读取并分类音视频包
    - 创建 `Sources/FFmpegSwiftSDK/Models/StreamInfo.swift`
    - _Requirements: 3.1_

  - [x] 5.2 实现 AudioDecoder 和 VideoDecoder
    - 创建 `Sources/FFmpegSwiftSDK/Engine/AudioDecoder.swift`
    - 实现音频解码，使用 SwrContext 将输出转换为 Float32 PCM
    - 创建 `Sources/FFmpegSwiftSDK/Engine/VideoDecoder.swift`
    - 实现视频解码，输出 CVPixelBuffer
    - 创建 `Sources/FFmpegSwiftSDK/Models/VideoFrame.swift`
    - 实现支持格式检查（H.264、H.265、AAC、MP3）
    - _Requirements: 3.2, 3.3, 3.4, 3.5_

  - [x] 5.3 编写不支持格式错误处理属性测试
    - **Property 2: 不支持编解码格式错误处理**
    - 使用 SwiftCheck 生成不在支持列表中的随机 codec ID，验证抛出 unsupportedFormat 错误
    - 最少 100 次迭代
    - **Validates: Requirements 3.4**

- [x] 6. 实现音视频同步与渲染
  - [x] 6.1 实现 AVSyncController
    - 创建 `Sources/FFmpegSwiftSDK/Engine/AVSyncController.swift`
    - 实现以音频时钟为主时钟的同步策略
    - 实现 calculateVideoDelay() 和 updateAudioClock() 方法
    - 偏差超过 40ms 时触发帧丢弃/重复补偿
    - _Requirements: 4.3_

  - [x] 6.2 编写音视频同步偏差属性测试
    - **Property 3: 音视频同步偏差控制**
    - 使用 SwiftCheck 生成随机单调递增 PTS 序列，验证同步偏差始终 ≤ 40ms
    - 最少 100 次迭代
    - **Validates: Requirements 4.3**

  - [x] 6.3 实现 AudioRenderer
    - 创建 `Sources/FFmpegSwiftSDK/Engine/AudioRenderer.swift`
    - 使用 CoreAudio AudioUnit (RemoteIO) 实现音频输出
    - 实现缓冲队列和 render callback
    - 实现 start/pause/resume/stop 控制
    - _Requirements: 4.2_

  - [x] 6.4 实现 VideoRenderer
    - 创建 `Sources/FFmpegSwiftSDK/Engine/VideoRenderer.swift`
    - 使用 CVPixelBuffer + CALayer 实现视频帧渲染
    - 实现 attach(to:)、render()、clear() 方法
    - _Requirements: 4.1_

- [x] 7. 检查点 - 核心引擎验证
  - 确保所有测试通过，如有问题请向用户确认。

- [x] 8. 实现公开 API 层
  - [x] 8.1 实现 StreamPlayer
    - 创建 `Sources/FFmpegSwiftSDK/API/StreamPlayer.swift`
    - 实现 PlaybackState 枚举和状态机
    - 实现 play(url:)、pause()、resume()、stop() 方法
    - play() 内部串联 ConnectionManager → Demuxer → Decoder → EQ → Renderer 流程
    - 在专用后台 DispatchQueue 上执行解复用和解码循环
    - 实现 StreamPlayerDelegate 回调通知状态变化
    - 暴露 state、currentTime、streamInfo 只读属性
    - _Requirements: 4.4, 4.5, 4.6, 6.1, 6.2, 6.3, 6.4, 6.5, 7.2_

  - [x] 8.2 实现 AudioEqualizer 公开 API
    - 创建 `Sources/FFmpegSwiftSDK/API/AudioEqualizer.swift`
    - 封装 EQFilter，提供 setGain()、gain(for:)、reset() 方法
    - 实现 AudioEqualizerDelegate 回调通知增益钳位
    - 将 AudioEqualizer 作为 StreamPlayer 的公开属性
    - _Requirements: 5.1, 5.2, 5.3, 5.4_

  - [x] 8.3 编写播放状态变化回调属性测试
    - **Property 8: 播放状态变化回调**
    - 使用 SwiftCheck 生成随机有效状态转换序列，验证 delegate 收到对应回调
    - 最少 100 次迭代
    - **Validates: Requirements 6.3**

  - [x] 8.4 编写播放会话重入属性测试
    - **Property 9: 播放会话重入**
    - 使用 SwiftCheck 生成随机正整数 N，执行 N 次 play/stop 循环，验证每次都能正常启动
    - 最少 100 次迭代
    - **Validates: Requirements 6.5**

- [x] 9. 集成与收尾
  - [x] 9.1 实现网络断连检测
    - 在 Demuxer 的读取循环中检测网络错误
    - 通过 ConnectionManager delegate 传播断连事件到 StreamPlayer
    - StreamPlayer 通过 delegate 通知应用层
    - _Requirements: 2.5_

  - [x] 9.2 实现不可恢复错误自动停止
    - 在核心引擎层识别不可恢复错误（资源分配失败、连接丢失等）
    - 自动触发 stop 流程并通过 delegate 通知
    - 可恢复错误（单帧解码失败）在引擎层处理，不传播
    - _Requirements: 7.4, 8.4_

  - [x] 9.3 创建公开 API 导出文件
    - 创建 `Sources/FFmpegSwiftSDK/FFmpegSwiftSDK.swift` 作为模块入口
    - 确保所有公开类型正确标记 public
    - 确保内部实现细节标记 internal 或 private
    - _Requirements: 1.2_

- [x] 10. 最终检查点 - 全部测试通过
  - 确保所有单元测试和属性测试通过，如有问题请向用户确认。

## 备注

- 所有任务均为必需任务，包括属性测试
- 每个任务引用了具体的需求编号以保证可追溯性
- 检查点任务确保增量验证
- 属性测试验证通用正确性属性，单元测试验证具体示例和边界条件
