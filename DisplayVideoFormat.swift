import Foundation
import CoreGraphics

/// One immutable, authenticated format per video session. This is NOT a request
/// to change the viewer's physical display. HiDPI renders real 2x backing pixels.
struct DisplayVideoFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelScale: Int
    init(width: Int, height: Int, pixelScale: Int = 1) { self.width=width;self.height=height;self.pixelScale=pixelScale }
    static let standard = DisplayVideoFormat(width: 1920, height: 1080)
    static let maximumPixels = 1920 * 1080
    static let maximumMacroblocks = 8704 // H.264 level 4.2 at 60 fps.
    static let maximumEncodedPixels = 4 * maximumPixels
    static let maximumEncodedMacroblocks = 34560 // H.264 level 5.2 at 60fps.
    var pixelWidth: Int { let p=width.multipliedReportingOverflow(by:pixelScale);return p.overflow ? 0:p.partialValue }
    var pixelHeight: Int { let p=height.multipliedReportingOverflow(by:pixelScale);return p.overflow ? 0:p.partialValue }
    var pixelSize: CGSize { CGSize(width:pixelWidth,height:pixelHeight) }
    var macroblockLimit: Int { pixelScale == 2 ? Self.maximumEncodedMacroblocks:Self.maximumMacroblocks }
    var h264LevelLimit: UInt32 { pixelScale == 2 ? 52:42 }
    var valid: Bool {
        width >= 640 && width <= 1920 && height >= 480 && height <= 1440 &&
        (pixelScale == 1 || pixelScale == 2) &&
        pixelWidth % 2 == 0 && pixelHeight % 2 == 0 &&
        width * height <= Self.maximumPixels &&
        pixelWidth * pixelHeight <= (pixelScale == 2 ? Self.maximumEncodedPixels:Self.maximumPixels) &&
        ((pixelWidth + 15) / 16) * ((pixelHeight + 15) / 16) <= macroblockLimit &&
        Double(width) / Double(height) >= 1.0 && Double(width) / Double(height) <= 2.4
    }
    var size: CGSize { CGSize(width: width, height: height) }
    /// Preserve the target aspect, rounded to even encoder dimensions. Do not
    /// exceed either dimension or the existing pixel/macroblock workload.
    static func fitting(_ target: CGSize) -> DisplayVideoFormat {
        guard target.width.isFinite, target.height.isFinite,
              target.width >= 1, target.height >= 1 else { return .standard }
        let ratio = target.width / target.height
        guard ratio >= 1, ratio <= 2.4 else { return .standard }
        let scale = min(sqrt(Double(maximumPixels) / Double(target.width * target.height)),
                        min(1920 / target.width, 1440 / target.height))
        guard scale.isFinite, scale > 0 else { return .standard }
        var width = Int((target.width * scale / 2).rounded(.down)) * 2
        var height = Int((target.height * scale / 2).rounded(.down)) * 2
        // Macroblock padding can exceed the pixel-based estimate. Shrink both
        // dimensions together; never change only one axis to fill the panel.
        while width >= 640 && height >= 480 {
            let result = Self(width: width, height: height)
            if result.valid {
                // Prefer virtually exact aspect ratios while retaining at least
                // 97% of the available pixels (e.g. 1808x1130 is exactly 16:10).
                // This avoids a visible hairline bar from independent rounding.
                let minimumPixels = Double(width * height) * 0.97
                var best: Self?
                for candidateWidth in stride(from: width, through: 640, by: -2) {
                    let idealHeight = Double(candidateWidth) / Double(ratio)
                    for candidateHeight in [Int((idealHeight / 2).rounded(.down)) * 2,
                                            Int((idealHeight / 2).rounded(.up)) * 2] {
                        let candidate = Self(width: candidateWidth, height: candidateHeight)
                        guard candidate.valid, Double(candidateWidth * candidateHeight) >= minimumPixels,
                              abs(Double(candidateWidth) / Double(candidateHeight) - Double(ratio)) <= 0.0001 else { continue }
                        if best == nil || candidateWidth * candidateHeight > best!.width * best!.height { best = candidate }
                    }
                }
                return best ?? result
            }
            let shrink = min(Double(width - 2) / Double(width), Double(height - 2) / Double(height))
            width = Int((Double(width) * shrink / 2).rounded(.down)) * 2
            height = Int((Double(height) * shrink / 2).rounded(.down)) * 2
        }
        return .standard
    }
    /// Match the viewer's logical safe fullscreen area, never inflate small
    /// screens merely to fill the budget. Actual backing/capture is always 2x.
    static func hiDPI(for target: CGSize) -> DisplayVideoFormat {
        guard target.width.isFinite,target.height.isFinite,target.width>0,target.height>0,
              target.width/target.height>=1,target.width/target.height<=2.4 else {
            return Self(width:1440,height:900,pixelScale:2)
        }
        let ratio=target.width/target.height
        let scale=min(1,min(sqrt(Double(maximumPixels)/Double(target.width*target.height)),min(1920/target.width,1440/target.height)))
        guard scale.isFinite,scale>0 else{return Self(width:1440,height:900,pixelScale:2)}
        var w=Int((target.width*scale).rounded(.down)),h=Int((target.height*scale).rounded(.down))
        while w>=640,h>=480 {
            let f=Self(width:w,height:h,pixelScale:2)
            if f.valid{return f}
            let shrink=min(Double(w-1)/Double(w),Double(h-1)/Double(h))
            w=Int((Double(w)*shrink).rounded(.down));h=Int((Double(h)*shrink).rounded(.down))
            // Keep the same rectangle aspect rather than shortening one axis.
            if Double(w)/Double(h)>Double(ratio){w=Int((Double(h)*Double(ratio)).rounded(.down))}
            else{h=Int((Double(w)/Double(ratio)).rounded(.down))}
        }
        return Self(width:1440,height:900,pixelScale:2)
    }
    /// Only accepted during the post-authentication v5 format exchange. The
    /// ordinary receive loop does not allow this packet or any reverse input.
    func encoded() throws -> Data {
        guard valid else { throw DisplayTransportError.invalid }
        return Data([5, 2, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255), UInt8(pixelScale)])
    }
    static func decode(_ data: Data) throws -> DisplayVideoFormat {
        guard data.count == 7 else { throw DisplayTransportError.invalid }
        let bytes = [UInt8](data)
        guard bytes[0] == 5, bytes[1] == 2 else { throw DisplayTransportError.invalid }
        let result = Self(width: Int(bytes[2]) * 256 + Int(bytes[3]), height: Int(bytes[4]) * 256 + Int(bytes[5]),pixelScale:Int(bytes[6]))
        guard result.valid else { throw DisplayTransportError.invalid }
        return result
    }
}

/// Called only after existing peer proof and encrypted role confirmation. The
/// closures exchange plaintext through the already-directional AEAD channels.
/// Exactly one proposal and matching echo; no renegotiation during streaming.
func displayNegotiateVideoFormat(sending: Bool, viewerFormat: DisplayVideoFormat,
    send: (Data) throws -> Void, receive: () throws -> Data) throws -> DisplayVideoFormat {
    if sending {
        let format = try DisplayVideoFormat.decode(receive())
        try send(format.encoded())
        return format
    }
    let proposal = try viewerFormat.encoded()
    try send(proposal)
    let echo = try receive()
    guard echo == proposal else { throw DisplayTransportError.invalid }
    return try DisplayVideoFormat.decode(echo)
}

/// Local test CLI only. Production formats are always peer-authenticated.
func displayTestFormat(arguments:[String],after index:Int)throws->DisplayVideoFormat {
    if arguments.count==index{return .standard}
    guard (arguments.count==index+3 || arguments.count==index+5),arguments[index]=="--size",
      let width=Int(arguments[index+1]),let height=Int(arguments[index+2]) else{throw DisplayTransportError.invalid}
    var scale=1
    if arguments.count==index+5 {guard arguments[index+3]=="--scale",let value=Int(arguments[index+4]) else{throw DisplayTransportError.invalid};scale=value}
    let format=DisplayVideoFormat(width:width,height:height,pixelScale:scale)
    guard format.valid else{throw DisplayTransportError.invalid};return format
}
