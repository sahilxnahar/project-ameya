import AmeyaCore
import Foundation
import SwiftUI

/// Audio and video tools: even volume, fades, trims, speed, channels, joining, audiobooks,
/// ringtones, GIFs for chat, frames, burned-in and automatic captions, and audio visualisers.
/// Panels live in AVToolPanels.swift; the engines in AmeyaEngines/MediaToolbox.swift.
extension ToolCatalog {
    static func avTools() -> [Tool] {
        soundTools() + combiningTools() + pictureTools()
    }

    // MARK: Which files

    /// Sound files Ameya can read: Ogg and Opus need the bundled helper.
    static func areSounds(_ formats: [FileFormat]) -> Bool {
        !formats.isEmpty && formats.allSatisfy { $0.family == .audio && (!$0.isFFmpegOnly || FFmpegAvailability.isAvailable) }
    }

    static func areSoundsOrVideos(_ formats: [FileFormat]) -> Bool {
        !formats.isEmpty && formats.allSatisfy { areSounds([$0]) || areVideos([$0]) }
    }

    /// Keeps a sound's format when Ameya can write it; otherwise AAC (M4A).
    static func keepSoundFormat(_ format: FileFormat) -> FileFormat {
        switch format {
        case .m4a, .wav, .aiff, .caf, .flac: format
        case .mp3, .ogg, .opus: FFmpegAvailability.isAvailable ? format : .m4a
        default: .m4a
        }
    }

    /// Sound keeps its format; a video keeps its own (or becomes MP4).
    static func keepMediaFormat(_ format: FileFormat) -> FileFormat {
        format.family == .video ? keepVideoFormat(format) : keepSoundFormat(format)
    }

    static func media(_ tool: MediaTool, target: @escaping (FileFormat) -> FileFormat) -> (FileFormat) -> ConversionRequest {
        { format in
            var options = ConversionOptions()
            options.media = tool
            return ConversionRequest(source: format, target: target(format), options: options)
        }
    }

    /// A panel whose result is a `MediaTool`.
    static func mediaPanel<Content: View>(_ content: @escaping @MainActor (@escaping (MediaTool) -> Void) -> Content) -> Tool.Panel {
        { _, done in
            AnyView(content { tool in
                var options = ConversionOptions()
                options.media = tool
                done(options)
            })
        }
    }

    // MARK: Sound

    static func soundTools() -> [Tool] {
        [
            Tool(id: "media.evenVolume", title: "Make the volume even…", systemImage: "speaker.wave.2",
                 help: "Makes quiet and loud recordings the same loudness for podcasts, music apps or TV, without distortion.",
                 outputSuffix: "(even volume)", isAvailable: areSoundsOrVideos,
                 makeRequest: media(.evenVolume(.podcast), target: keepMediaFormat),
                 panel: mediaPanel { done in EvenVolumePanel(finish: done) }),
            Tool(id: "media.fade", title: "Fade in and out…", systemImage: "waveform.path.ecg",
                 help: "Makes the sound rise gently at the start and fall gently at the end.",
                 outputSuffix: "(faded)", isAvailable: areSoundsOrVideos,
                 makeRequest: media(.fade(inSeconds: 2, outSeconds: 3), target: keepMediaFormat),
                 panel: mediaPanel { done in FadePanel(finish: done) }),
            Tool(id: "media.trimAudio", title: "Trim sound…", systemImage: "scissors",
                 help: "Choose where the sound starts and ends.",
                 outputSuffix: "(trimmed)", isAvailable: areSounds,
                 makeRequest: media(.trimAudio(start: nil, end: nil), target: keepSoundFormat),
                 panel: mediaPanel { done in TrimSoundPanel(finish: done) }),
            Tool(id: "media.speed", title: "Change speed…", systemImage: "gauge.with.dots.needle.67percent",
                 help: "Plays faster or slower, from half to double speed, without changing the pitch of voices.",
                 outputSuffix: "(speed)", isAvailable: areSoundsOrVideos,
                 makeRequest: media(.speed(1.5), target: keepMediaFormat),
                 panel: mediaPanel { done in SpeedPanel(finish: done) }),
            Tool(id: "media.channels", title: "Mono or stereo…", systemImage: "headphones",
                 help: "Mix left and right into one, swap them, or keep only one side.",
                 outputSuffix: "(mono)", isAvailable: areSoundsOrVideos,
                 makeRequest: media(.channels(.mono), target: keepMediaFormat),
                 panel: mediaPanel { done in ChannelsPanel(finish: done) }),
        ].map { tool in
            var tool = tool
            if tool.id == "media.speed" {
                tool.suffixForOptions = { options in
                    if case .speed(let factor) = options.media { return "(\(SpeedPanel.label(factor)))" }
                    return "(speed)"
                }
            } else if tool.id == "media.channels" {
                tool.suffixForOptions = { options in
                    guard case .channels(let mix) = options.media else { return "(mono)" }
                    return switch mix {
                    case .mono: "(mono)"
                    case .swap: "(swapped)"
                    case .leftOnly: "(left)"
                    case .rightOnly: "(right)"
                    }
                }
            }
            return tool
        }
    }

    // MARK: Several files into one

    static func combiningTools() -> [Tool] {
        let join = Tool(
            id: "media.joinAudio", title: "Join audio", systemImage: "link",
            help: "Puts these sound files one after another, in this order, into one file.",
            mode: .allTogether, outputSuffix: "(joined)",
            isAvailable: { $0.count >= 2 && areSounds($0) },
            makeRequest: media(.joinAudio, target: keepSoundFormat)
        )
        let videos = Tool(
            id: "media.joinVideos", title: "Join videos", systemImage: "film.stack",
            help: "Puts these videos one after another, in this order, into one. Other shapes get black bars.",
            mode: .allTogether, outputSuffix: "(joined)",
            isAvailable: { $0.count >= 2 && areVideos($0) },
            makeRequest: media(.joinVideos, target: keepVideoFormat)
        )
        var book = Tool(
            id: "media.audiobook", title: "Make an audiobook…", systemImage: "book.closed",
            help: "Joins these sound files into one audiobook (M4B) with a chapter for each file. Add a picture for the cover.",
            mode: .allTogether, outputSuffix: "(audiobook)",
            isAvailable: { formats in
                let sounds = formats.filter { $0.family == .audio }
                let pictures = formats.filter { $0.family == .image && !$0.isIcon && $0 != .pdf }
                return !sounds.isEmpty && areSounds(sounds) && pictures.count <= 1 && sounds.count + pictures.count == formats.count
                    && formats.count >= 2
            },
            makeRequest: media(.audiobook(title: nil, chapterTitles: []), target: { _ in .m4a }),
            panel: mediaPanel { done in AudiobookPanel(finish: done) }
        )
        book.outputExtension = "m4b"
        book.finishRequest = { request, urls in
            guard case .audiobook(let title, _) = request.options.media, let formats = request.inputs else { return }
            // Chapters are named after the sound files, without their extensions.
            let names = zip(urls, formats).filter { $0.1.family == .audio }.map { $0.0.deletingPathExtension().lastPathComponent }
            request.options.media = .audiobook(title: title, chapterTitles: names)
        }
        var ringtone = Tool(
            id: "media.ringtone", title: "Make a ringtone…", systemImage: "bell",
            help: "Makes a 30-second iPhone ringtone (M4R) from the part you choose, with a gentle fade.",
            outputSuffix: "(ringtone)", isAvailable: { $0.count == 1 && areSoundsOrVideos($0) },
            makeRequest: media(.ringtone(start: 0, seconds: 30), target: { _ in .m4a }),
            panel: mediaPanel { done in RingtonePanel(finish: done) }
        )
        ringtone.outputExtension = "m4r"
        return [join, videos, book, ringtone]
    }

    // MARK: Pictures from video, video from sound

    static func pictureTools() -> [Tool] {
        let oneVideo: ([FileFormat]) -> Bool = { $0.count == 1 && areVideos($0) }
        var frames = Tool(
            id: "media.frames", title: "Save frames…", systemImage: "photo.stack",
            help: "Saves still pictures from the video every few seconds or frames, in a folder.",
            outputSuffix: "(frames)", producesFolder: true, isAvailable: areVideos,
            makeRequest: media(.extractFrames(.everySeconds(1), format: .png), target: { _ in .png }),
            panel: mediaPanel { done in FramesPanel(finish: done) }
        )
        frames.folderForOptions = { _ in true }
        return [
            Tool(id: "media.gif", title: "GIF for chat…", systemImage: "photo.on.rectangle.angled",
                 help: "Makes an animated GIF small enough for chat apps, such as under 5 MB. Sound is left out.",
                 outputSuffix: "(GIF)", isAvailable: areVideos,
                 makeRequest: media(.gif(targetBytes: 5_000_000), target: { _ in .gif }),
                 panel: mediaPanel { done in GIFSizePanel(finish: done) }),
            frames,
            Tool(id: "media.burnSubtitles", title: "Burn in subtitles", systemImage: "captions.bubble",
                 help: "Draws the captions from the subtitle file into the video's picture, so they show everywhere.",
                 mode: .allTogether, outputSuffix: "(captions)",
                 isAvailable: { formats in
                     formats.count == 2 && formats.filter { areVideos([$0]) }.count == 1 && formats.contains { $0.family == .subtitle }
                 },
                 makeRequest: media(.burnSubtitles, target: { _ in .mp4 })),
            Tool(id: "media.autoCaption", title: "Add captions automatically", systemImage: "captions.bubble.fill",
                 help: "Recognises the speech on this Mac and draws it into the video as captions.",
                 outputSuffix: "(captions)", isAvailable: oneVideo,
                 makeRequest: media(.autoCaption, target: { _ in .mp4 })),
            Tool(id: "media.visualiser", title: "Turn sound into video…", systemImage: "waveform.circle",
                 help: "Makes a square video with moving bars or a wave, to share a recording on apps that only take video.",
                 outputSuffix: "(video)", isAvailable: { $0.count == 1 && areSounds($0) },
                 makeRequest: media(.visualiser(style: .bars, background: VisualiserPanel.colours[0].colour), target: { _ in .mp4 }),
                 panel: mediaPanel { done in VisualiserPanel(finish: done) }),
        ]
    }
}
