// 아이폰 화면 공유 방송 확장 — LiveKit Flutter SDK 예제(livekit_client 2.13.0 example/ios, Apache-2.0)의 파일을 그대로 가져왔다.
// 앱(flutter_webrtc)과 같은 방식으로 앱 그룹 폴더의 유닉스 소켓(rtc_SSFD)에 화면 프레임을 보낸다 — 고치면 앱 쪽과 어긋날 수 있다.

//
//  Atomic.swift
//  Broadcast Extension
//
//  Created by Maksym Shcheglov.
//  https://www.onswiftwings.com/posts/atomic-property-wrapper/
//

import Foundation

@propertyWrapper
struct Atomic<Value> {

    private var value: Value
    private let lock = NSLock()

    init(wrappedValue value: Value) {
        self.value = value
    }

    var wrappedValue: Value {
        get { load() }
        set { store(newValue: newValue) }
    }

    func load() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    mutating func store(newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
