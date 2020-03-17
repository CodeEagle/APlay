class PacketPackage {
    
    var id: Int { return index }
    @Clamping(initialValue: 0, range: 0 ... Int.max)
    private var index: Int
    private(set) var data: Data
    private(set) var packetDesc: AudioStreamPacketDescription?
    var next: PacketPackage?
    
    init(index: Int, data: Data, packetDesc: AudioStreamPacketDescription?) {
        self.data = data
        self.index = index
        self.packetDesc = packetDesc
    }
}
