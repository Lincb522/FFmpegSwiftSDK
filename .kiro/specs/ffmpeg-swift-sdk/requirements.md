# 需求文档

## 简介

本项目旨在构建一个基于 FFmpeg 的 Swift SDK，通过 C bridging 封装 FFmpeg 底层能力，为 Swift 开发者提供友好的 API。SDK 聚焦两大核心功能：流媒体播放（支持 RTMP/HLS/RTSP 等协议的音视频解码与渲染）和实时音频均衡器（对音频流进行低频/中频/高频增益的实时调节）。SDK 需要兼顾线程安全、内存管理和性能优化。

## 术语表

- **SDK**: 本项目提供的 Swift 软件开发工具包，封装 FFmpeg 能力
- **FFmpeg_Bridge**: 负责将 FFmpeg C 库桥接到 Swift 的模块，通过 module map 或 Swift Package Manager 实现
- **Stream_Player**: 流媒体播放器组件，负责协议连接、解码和渲染
- **Audio_EQ**: 实时音频均衡器组件，负责对音频 PCM 数据进行频段增益处理
- **Demuxer**: 解复用器，从容器格式中分离音频流和视频流
- **Decoder**: 解码器，将压缩的音视频数据解码为原始帧数据
- **Renderer**: 渲染器，将解码后的视频帧输出到显示层，将音频帧输出到音频设备
- **EQ_Filter**: 均衡器滤波器，对音频 PCM 数据按频段施加增益
- **PCM_Data**: 脉冲编码调制数据，解码后的原始音频采样数据
- **Gain_Parameter**: 增益参数，表示某一频段的增益值，单位为分贝（dB）

## 需求

### 需求 1：FFmpeg C 库桥接

**用户故事：** 作为 Swift 开发者，我希望通过 Swift Package Manager 集成 FFmpeg，以便在 Swift 代码中直接调用 FFmpeg 的 C 函数。

#### 验收标准

1. THE FFmpeg_Bridge SHALL 通过 module map 将 FFmpeg 的 libavformat、libavcodec、libavutil、libswresample、libavfilter 头文件暴露给 Swift
2. THE FFmpeg_Bridge SHALL 提供 Swift 友好的类型别名和封装，隐藏底层 C 指针操作
3. WHEN FFmpeg_Bridge 初始化时，THE FFmpeg_Bridge SHALL 调用 FFmpeg 的全局注册函数完成初始化
4. THE FFmpeg_Bridge SHALL 通过 Swift Package Manager 的 systemLibrary 或 binaryTarget 方式集成 FFmpeg 库

### 需求 2：流媒体连接与协议支持

**用户故事：** 作为应用开发者，我希望 SDK 支持多种流媒体协议，以便播放不同来源的音视频流。

#### 验收标准

1. WHEN 提供一个有效的 RTMP URL 时，THE Stream_Player SHALL 成功建立连接并开始接收数据
2. WHEN 提供一个有效的 HLS URL 时，THE Stream_Player SHALL 成功建立连接并开始接收数据
3. WHEN 提供一个有效的 RTSP URL 时，THE Stream_Player SHALL 成功建立连接并开始接收数据
4. WHEN 提供一个无效或不可达的 URL 时，THE Stream_Player SHALL 在 10 秒内返回包含错误原因的连接失败错误
5. WHEN 连接建立后网络中断时，THE Stream_Player SHALL 检测到断连并通过回调通知调用方
6. IF 连接过程中发生超时，THEN THE Stream_Player SHALL 返回超时错误并释放已分配的资源

### 需求 3：音视频解复用与解码

**用户故事：** 作为应用开发者，我希望 SDK 能自动解复用和解码音视频流，以便获取可渲染的原始帧数据。

#### 验收标准

1. WHEN 流连接建立后，THE Demuxer SHALL 从容器格式中分离出音频流和视频流
2. WHEN Demuxer 输出音频包时，THE Decoder SHALL 将压缩音频数据解码为 PCM_Data
3. WHEN Demuxer 输出视频包时，THE Decoder SHALL 将压缩视频数据解码为原始视频帧（YUV 或 RGB 格式）
4. IF 遇到不支持的编解码格式，THEN THE Decoder SHALL 返回明确的不支持格式错误
5. THE Decoder SHALL 支持 H.264、H.265、AAC、MP3 编解码格式

### 需求 4：音视频渲染输出

**用户故事：** 作为应用开发者，我希望 SDK 提供音视频同步渲染能力，以便在界面上流畅播放音视频内容。

#### 验收标准

1. THE Renderer SHALL 将解码后的视频帧渲染到调用方提供的显示视图上
2. THE Renderer SHALL 将解码后的音频 PCM_Data 输出到系统音频设备进行播放
3. WHILE 播放进行中，THE Renderer SHALL 基于 PTS（Presentation Time Stamp）保持音视频同步，音视频偏差不超过 40 毫秒
4. WHEN 调用方请求暂停时，THE Stream_Player SHALL 暂停音视频渲染并保持当前状态
5. WHEN 调用方请求恢复播放时，THE Stream_Player SHALL 从暂停位置继续渲染
6. WHEN 调用方请求停止时，THE Stream_Player SHALL 停止渲染并释放所有相关资源

### 需求 5：实时音频均衡器

**用户故事：** 作为应用开发者，我希望对音频流进行实时均衡器处理，以便用户可以调节不同频段的音量效果。

#### 验收标准

1. THE Audio_EQ SHALL 支持至少三个频段的增益调节：低频（20-300Hz）、中频（300-4000Hz）、高频（4000-20000Hz）
2. WHEN 调用方设置某一频段的 Gain_Parameter 时，THE EQ_Filter SHALL 在下一个音频缓冲区处理周期内应用新的增益值
3. THE EQ_Filter SHALL 接受范围为 -12dB 到 +12dB 的 Gain_Parameter 值
4. IF 提供的 Gain_Parameter 超出 -12dB 到 +12dB 范围，THEN THE Audio_EQ SHALL 将该值钳位到最近的边界值并通知调用方
5. WHEN 所有频段的 Gain_Parameter 均为 0dB 时，THE EQ_Filter SHALL 输出与输入 PCM_Data 在数值精度范围内一致的数据
6. THE Audio_EQ SHALL 在不引入可感知延迟的前提下处理音频数据，单次缓冲区处理耗时不超过缓冲区时长的 50%
7. WHILE EQ 处理进行中，THE Audio_EQ SHALL 保证线程安全，允许在播放线程处理音频的同时从其他线程修改 Gain_Parameter

### 需求 6：播放控制接口

**用户故事：** 作为应用开发者，我希望 SDK 提供简洁的播放控制 API，以便轻松集成到应用中。

#### 验收标准

1. THE Stream_Player SHALL 提供 play(url:)、pause()、resume()、stop() 方法
2. WHEN play(url:) 被调用时，THE Stream_Player SHALL 依次执行连接、解复用、解码和渲染流程
3. THE Stream_Player SHALL 通过 delegate 或 closure 回调通知调用方播放状态变化（连接中、播放中、暂停、停止、错误）
4. THE Stream_Player SHALL 提供只读属性获取当前播放状态、已播放时长和流媒体信息
5. WHEN stop() 被调用后再次调用 play(url:) 时，THE Stream_Player SHALL 能够正常开始新的播放会话

### 需求 7：资源管理与线程安全

**用户故事：** 作为应用开发者，我希望 SDK 能正确管理内存和线程，以避免内存泄漏和崩溃。

#### 验收标准

1. WHEN Stream_Player 被销毁时，THE Stream_Player SHALL 释放所有 FFmpeg 上下文、缓冲区和系统资源
2. THE SDK SHALL 在专用的后台线程上执行解复用和解码操作，避免阻塞主线程
3. WHILE 多个组件并发访问共享状态时，THE SDK SHALL 通过适当的同步机制保证数据一致性
4. IF FFmpeg C 函数返回错误码，THEN THE SDK SHALL 将错误码转换为 Swift Error 类型并传递给调用方
5. THE SDK SHALL 确保所有通过 av_malloc 分配的内存在对应上下文释放时被正确回收

### 需求 8：错误处理

**用户故事：** 作为应用开发者，我希望 SDK 提供清晰的错误信息，以便快速定位和解决问题。

#### 验收标准

1. THE SDK SHALL 定义统一的 FFmpegError 枚举类型，涵盖连接错误、解码错误、格式不支持、资源分配失败等类别
2. WHEN FFmpeg C 函数返回负数错误码时，THE SDK SHALL 将其映射为对应的 FFmpegError 枚举值
3. THE FFmpegError SHALL 包含人类可读的错误描述信息和原始 FFmpeg 错误码
4. IF 发生不可恢复的错误，THEN THE Stream_Player SHALL 自动停止播放并通过回调通知调用方
