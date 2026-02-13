// MetadataReader.swift
// FFmpegSwiftSDK
//
// 读取音频文件的元数据（ID3 标签、Vorbis Comment 等）。
// 提取标题、艺术家、专辑、年份、专辑封面等信息。

import Foundation
import CFFmpeg

/// 音频文件元数据。
public struct AudioMetadata {
    /// 歌曲标题
    public let title: String?
    /// 艺术家
    public let artist: String?
    /// 专辑名
    public let album: String?
    /// 专辑艺术家
    public let albumArtist: String?
    /// 年份
    public let year: String?
    /// 曲目编号
    public let trackNumber: String?
    /// 流派
    public let genre: String?
    /// 作曲家
    public let composer: String?
    /// 专辑封面图片数据（JPEG/PNG）
    public let artworkData: Data?
    /// 专辑封面 MIME 类型（如 "image/jpeg"）
    public let artworkMimeType: String?
    /// 所有原始标签键值对
    public let rawTags: [String: String]
}

/// 音频元数据读取器。
///
/// 使用 FFmpeg 的 AVFormatContext 读取各种格式的元数据标签，
/// 支持 ID3v1/v2（MP3）、Vorbis Comment（FLAC/OGG）、
/// iTunes Metadata（M4A/AAC）等。
///
/// ```swift
/// let reader = MetadataReader()
/// let metadata = try reader.read(url: "file:///path/to/song.flac")
/// print(metadata.title)   // 歌曲标题
/// print(metadata.artist)  // 艺术家
/// // metadata.artworkData  // 专辑封面 Data（可直接转 UIImage）
/// ```
public final class MetadataReader {

    public init() {}

    /// 读取音频文件的元数据。
    ///
    /// - Parameter url: 文件路径或 URL
    /// - Returns: AudioMetadata
    /// - Throws: FFmpegError
    public func read(url: String) throws -> AudioMetadata {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        let ret = avformat_open_input(&fmtCtx, url, nil, nil)
        guard ret >= 0, let ctx = fmtCtx else {
            throw FFmpegError.connectionFailed(code: ret, message: "无法打开文件: \(url)")
        }
        defer { avformat_close_input(&fmtCtx) }

        avformat_find_stream_info(ctx, nil)

        // 读取容器级别的标签
        var rawTags = [String: String]()
        if let metadata = ctx.pointee.metadata {
            rawTags = extractTags(from: metadata)
        }

        // 也检查各个流的标签（有些格式把标签放在流上）
        for i in 0..<Int(ctx.pointee.nb_streams) {
            if let stream = ctx.pointee.streams[i], let metadata = stream.pointee.metadata {
                let streamTags = extractTags(from: metadata)
                for (key, value) in streamTags where rawTags[key] == nil {
                    rawTags[key] = value
                }
            }
        }

        // 提取专辑封面
        var artworkData: Data?
        var artworkMimeType: String?
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i] else { continue }
            let codecpar = stream.pointee.codecpar
            // 封面通常是 MJPEG 或 PNG 编码的视频流，disposition 标记为 attached_pic
            if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                let pkt = stream.pointee.attached_pic
                if pkt.size > 0, let data = pkt.data {
                    artworkData = Data(bytes: data, count: Int(pkt.size))
                    // 判断 MIME 类型
                    if let cp = codecpar {
                        let codecID = cp.pointee.codec_id
                        if codecID == AV_CODEC_ID_MJPEG || codecID == AV_CODEC_ID_JPEG2000 {
                            artworkMimeType = "image/jpeg"
                        } else if codecID == AV_CODEC_ID_PNG {
                            artworkMimeType = "image/png"
                        } else if codecID == AV_CODEC_ID_BMP {
                            artworkMimeType = "image/bmp"
                        } else {
                            artworkMimeType = "image/jpeg" // 默认
                        }
                    }
                }
                break
            }
        }

        return AudioMetadata(
            title: rawTags["title"] ?? rawTags["TITLE"],
            artist: rawTags["artist"] ?? rawTags["ARTIST"],
            album: rawTags["album"] ?? rawTags["ALBUM"],
            albumArtist: rawTags["album_artist"] ?? rawTags["ALBUMARTIST"],
            year: rawTags["date"] ?? rawTags["DATE"] ?? rawTags["year"] ?? rawTags["YEAR"],
            trackNumber: rawTags["track"] ?? rawTags["TRACKNUMBER"],
            genre: rawTags["genre"] ?? rawTags["GENRE"],
            composer: rawTags["composer"] ?? rawTags["COMPOSER"],
            artworkData: artworkData,
            artworkMimeType: artworkMimeType,
            rawTags: rawTags
        )
    }

    /// 从 AVDictionary 提取所有键值对。
    /// AVDictionary 在 Swift 中是不透明类型，需要用 OpaquePointer 传递。
    private func extractTags(from dict: OpaquePointer) -> [String: String] {
        var tags = [String: String]()
        var entry: UnsafeMutablePointer<AVDictionaryEntry>?
        while true {
            entry = av_dict_get(dict, "", entry, AV_DICT_IGNORE_SUFFIX)
            guard let e = entry else { break }
            let key = String(cString: e.pointee.key)
            let value = String(cString: e.pointee.value)
            tags[key] = value
        }
        return tags
    }
}
