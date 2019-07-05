// MARK: - AudioFileType

/// A wrap for AudioFileTypeID
public struct AudioFileType: RawRepresentable, Hashable {
    public typealias RawValue = String
    public var rawValue: String
    
    public init(rawValue: RawValue) { self.rawValue = rawValue }
    
    public init(_ value: RawValue) { rawValue = value }
    
    public init?(value: AudioFileTypeID) {
        guard let result = String(from: value) else { return nil }
        self.init(rawValue: result)
    }
    // https://developer.apple.com/documentation/audiotoolbox/1576497-anonymous?language=objc
    public static let aiff = AudioFileType("AIFF")
    public static let aifc = AudioFileType("AIFC")
    public static let wave = AudioFileType("WAVE")
    public static let rf64 = AudioFileType("RF64")
    public static let soundDesigner2 = AudioFileType("Sd2f")
    public static let next = AudioFileType("NeXT")
    public static let mp3 = AudioFileType("MPG3")
    public static let mp2 = AudioFileType("MPG2")
    public static let mp1 = AudioFileType("MPG1")
    public static let ac3 = AudioFileType("ac-3")
    public static let aacADTS = AudioFileType("adts")
    public static let mp4 = AudioFileType("mp4f")
    public static let m4a = AudioFileType("m4af")
    public static let m4b = AudioFileType("m4bf")
    public static let caf = AudioFileType("caff")
    public static let k3gp = AudioFileType("3gpp")
    public static let k3gp2 = AudioFileType("3gp2")
    public static let amr = AudioFileType("amrf")
    public static let flac = AudioFileType("flac")
    public static let opus = AudioFileType("opus")
    
    private static var map: [AudioFileType: AudioFileTypeID] = [:]
    
    public var audioFileTypeID: AudioFileTypeID {
        let value: AudioFileTypeID
        if let result = AudioFileType.map[self] {
            value = result
        } else {
            value = rawValue.audioFileTypeID()
            AudioFileType.map[self] = value
        }
        return value
    }
}
