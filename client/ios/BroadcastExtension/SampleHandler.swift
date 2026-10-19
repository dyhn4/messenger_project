// 아이폰 화면 공유 — 방송 확장(Broadcast Upload Extension)의 본체. 화상회의 화면에서 [화면 공유]를 누르면 iOS의 "화면 방송" 창이
// 뜨고(LiveKit BroadcastManager), 사용자가 [방송 시작]을 누르면 iOS가 이 확장을 따로 띄워 화면 프레임을 넘겨준다. 확장은 그
// 프레임을 앱 그룹 폴더의 유닉스 소켓(rtc_SSFD)으로 앱에 보내고, 앱(flutter_webrtc)이 받아 LiveKit 화면 공유로 올린다.
// 다른 앱으로 가도 화면 전체가 나간다. 멈추기: 앱의 [화면 공유]를 다시 누르면 앱이 소켓을 닫아 여기서 방송을 마치고, 제어 센터·빨간
// 상태 막대에서 멈추면 broadcastFinished로 앱에 알린다(DarwinNotification — 앱이 공유를 내린다).
//
// LiveKit Flutter SDK 예제(livekit_client 2.13.0 example/ios, Apache-2.0)의 SampleHandler를 이 앱의 앱 그룹에 맞춘 것.

import OSLog
import ReplayKit

let broadcastLogger = OSLog(subsystem: "com.teamtalk.messenger.BroadcastExtension", category: "Broadcast")

private enum Constants {
    /// 앱과 이 확장이 같이 쓰는 앱 그룹 — Runner.entitlements·BroadcastExtension.entitlements, Info.plist의 RTCAppGroupIdentifier와 같아야 한다.
    static let appGroupIdentifier = "group.com.teamtalk.messenger"
}

class SampleHandler: RPBroadcastSampleHandler {

    private var clientConnection: SocketConnection?
    private var uploader: SampleUploader?

    var socketFilePath: String {
        let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupIdentifier)
        return sharedContainer?.appendingPathComponent("rtc_SSFD").path ?? ""
    }

    override init() {
        super.init()
        if let connection = SocketConnection(filePath: socketFilePath) {
            clientConnection = connection
            setupConnection()
            uploader = SampleUploader(connection: connection)
        }
        os_log(.debug, log: broadcastLogger, "%{public}s", socketFilePath)
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 앱(LiveKit)이 이 알림을 받고 화면 공유를 올린다 — 그 사이 앱이 소켓을 열 때까지 아래 openConnection이 다시 붙어 본다.
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        openConnection()
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        // 제어 센터·빨간 상태 막대에서 멈췄다 — 앱이 화면 공유를 내린다.
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        clientConnection?.close()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            uploader?.send(sample: sampleBuffer)
        default:
            // 소리는 보내지 않는다 — 화상회의의 마이크가 따로 나간다.
            break
        }
    }
}

private extension SampleHandler {

    func setupConnection() {
        clientConnection?.didClose = { [weak self] error in
            os_log(.debug, log: broadcastLogger, "client connection did close \(String(describing: error))")
            if let error = error {
                self?.finishBroadcastWithError(error)
            } else {
                // 앱이 공유를 내려 소켓을 닫았다(앱의 [화면 공유]를 다시 누름·통화 종료). iOS가 이 글을 "방송 종료" 창에 보여 준다 —
                // 실패가 아니라는 걸 알 수 있게 NSError로 넘긴다.
                let screenSharingStopped = 10001
                let customError = NSError(
                    domain: RPRecordingErrorDomain,
                    code: screenSharingStopped,
                    userInfo: [NSLocalizedDescriptionKey: "화면 공유를 마쳤습니다."]
                )
                self?.finishBroadcastWithError(customError)
            }
        }
    }

    /// 앱이 소켓을 열어 둘 때까지 0.1초마다 붙어 본다 — 방송 시작 알림을 받은 앱이 화면 공유를 올리며 소켓을 연다.
    func openConnection() {
        let queue = DispatchQueue(label: "broadcast.connectTimer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard self?.clientConnection?.open() == true else {
                return
            }
            timer.cancel()
        }
        timer.resume()
    }
}
