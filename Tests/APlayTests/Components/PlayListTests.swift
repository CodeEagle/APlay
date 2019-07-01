final class PlayListTests: XCTestCase {
    
    private func runIn(_ closure: (PlayList, XCTestExpectation) -> Void) {
        asyncTest { (e) in
            let sender: PassthroughSubject<Event, Never> = .init()
            _ = sender.sink { (event) in
                print(event)
            }
            
            let playList: PlayList = .init()
            _ = playList.playingIndexPublisher.sink { (indx) in
                sender.send(.playingIndexChanged(indx))
            }
            _ = playList.listPublisher.sink { (list) in
                sender.send(.playlistChanged(list))
            }
            _ = playList.loopPatternPublisher.sink { (pattern) in
                sender.send(.playLoopPatternChanged(pattern))
            }
            closure(playList, e)
        }
    }
    
    func testAddSubscriber() {
        runIn { (playList, e) in
            let indexSc: AnySubscriber<PlayingIndex, Never> = .init(receiveSubscription: { (sc) in
                sc.request(Subscribers.Demand.unlimited)
                print("receiveSubscription: \(sc)")
            }, receiveValue: { (index) -> Subscribers.Demand in
                print("receiveValue: \(index)")
                return .unlimited
            }, receiveCompletion: { result in
                print("receiveCompletion: \(result)")
            })
            playList.addPlayingIndexSubscriber(indexSc)
            
            
            let listSc: AnySubscriber<[URL], Never> = .init(receiveSubscription: { (sc) in
                sc.request(Subscribers.Demand.unlimited)
                print("receiveSubscription: \(sc)")
            }, receiveValue: { (val) -> Subscribers.Demand in
                print("receiveValue: \(val)")
                return .unlimited
            }, receiveCompletion: { result in
                print("receiveCompletion: \(result)")
            })
            playList.addListSubscriber(listSc)
            
            playList.changeList(to: [URL(string: "https://none.url")!], at: 0)
            playList.changeList(to: [URL(string: "https://none.url")!, URL(string: "https://none.url.1")!], at: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                e.fulfill()
            }
        }
        
    }
    
    func testAddPublisher() {
        runIn { (playList, e) in
            
            let pub = playList.playingIndexPublisher
            _ = pub.sink { (index) in
                print("pub index changed to: \(String.init(describing: index))")
            }
            
            let pub2 = playList.playingIndexPublisher
            _ = pub2.sink { (index) in
                print("pub2 index changed to: \(String.init(describing: index))")
            }
            playList.changeList(to: [URL(string: "https://none.url")!], at: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                e.fulfill()
            }
        }
    }
    
    func testChangeList() {
        runIn { (playList, e) in
            
            let group = DispatchGroup()
            var latestList: [URL] = []
            var latestIndex: UInt = 999
            let lock: UnfairLock = .init()
            group.enter()
            DispatchQueue.global(qos: .background).async {
                let list2: [URL] = [URL(string: "https://none.url.3")!, URL(string: "https://none.url.4")!]
                lock.lock {
                    playList.changeList(to: list2, at: 1)
                    latestList = list2
                    latestIndex = 1
                    print("One")
                    group.leave()
                }
            }
            
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let list: [URL] = [URL(string: "https://none.url")!, URL(string: "https://none.url.2")!]
                lock.lock {
                    playList.changeList(to: list, at: 0)
                    latestList = list
                    latestIndex = 0
                    print("Zero")
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let rawStr = playList.list.map({ $0.absoluteString }).joined()
                let expect = latestList.map({ $0.absoluteString }).joined()
                assert(rawStr == expect)
                assert(playList.playingIndex.value == latestIndex)
                e.fulfill()
            }
        }
    }
}
