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

class PacketManager {
    private var _packetCount: Int = 0
    // to schedule next packet id
    private var _toSchedulePacketId: Int = 0
    private let policy: APlay.Configuration.SeekPolicy

    /// ThreadSafe Queue
    private var _queue: DispatchQueue = DispatchQueue(concurrentName: "PacketManager")

    // MARK: Disable Seek

    private var _packetHead: PacketPackage?
    private weak var _packetTail: PacketPackage?

    // MARK: Enable Seek

    private lazy var _list: [PacketPackage] = []

    init(policy: APlay.Configuration.SeekPolicy) {
        self.policy = policy
    }

    private(set) var packetCount: Int {
        get { return _queue.sync { self._packetCount } }
        set { _queue.asyncWrite { self._packetCount = newValue } }
    }

    private(set) var toSchedulePacketId: Int {
        get { return _queue.sync { self._toSchedulePacketId } }
        set { _queue.asyncWrite { self._toSchedulePacketId = newValue } }
    }

    private var packetHead: PacketPackage? {
        get { return _queue.sync { self._packetHead } }
        set { _queue.asyncWrite { self._packetHead = newValue } }
    }

    private var packetTail: PacketPackage? {
        get { return _queue.sync { self._packetTail } }
        set { _queue.asyncWrite { self._packetTail = newValue } }
    }

    private var list: [PacketPackage] {
        get { return _queue.sync { self._list } }
        set { _queue.asyncWrite { self._list = newValue } }
    }

    func createPacket(_ val: [(Data, AudioStreamPacketDescription?)]) {
        for item in val {
            autoreleasepool {
                let packet = PacketPackage(index: packetCount, data: item.0, packetDesc: item.1)
                if policy == .disable {
                    if packetHead == nil {
                        packetHead = packet
                        packetTail = packetHead
                    } else {
                        if packetTail?.next == nil {
                            packetTail?.next = packet
                        }
                        packetTail = packet
                    }
                } else {
                    list.append(packet)
                }
                packetCount &+= 1
            }
        }
    }

    func nextPacket() -> PacketPackage? {
        if policy == .disable {
            if packetHead == nil { return nil }
            let ret = packetHead
            packetHead = packetHead?.next
            return ret
        } else {
            return list[safe: toSchedulePacketId]
        }
    }

    func increaseScheduledPacketId() {
        toSchedulePacketId &+= 1
    }

    func changeNextSchedulePacketId(to index: Int) {
        toSchedulePacketId = index
    }

    func reset() {
        packetCount = 0
        toSchedulePacketId = 0
        autoreleasepool {
            if policy == .disable {
                packetHead = nil
                packetTail = nil
            } else {
                list = []
            }
        }
    }
}
