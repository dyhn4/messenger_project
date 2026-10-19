// 아이폰 화면 공유 방송 확장 — LiveKit Flutter SDK 예제(livekit_client 2.13.0 example/ios, Apache-2.0)의 파일을 그대로 가져왔다.
// 앱(flutter_webrtc)과 같은 방식으로 앱 그룹 폴더의 유닉스 소켓(rtc_SSFD)에 화면 프레임을 보낸다 — 고치면 앱 쪽과 어긋날 수 있다.

//
//  DarwinNotificationCenter.swift
//  Broadcast Extension
//
//  Created by Alex-Dan Bumbu on 23/03/2021.
//  Copyright © 2021 8x8, Inc. All rights reserved.
//

import Foundation

enum DarwinNotification: String {
    case broadcastStarted = "iOS_BroadcastStarted"
    case broadcastStopped = "iOS_BroadcastStopped"
}

class DarwinNotificationCenter {
    
    static let shared = DarwinNotificationCenter()
    
    private let notificationCenter: CFNotificationCenter
    
    init() {
        notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    }
    
    func postNotification(_ name: DarwinNotification) {
        CFNotificationCenterPostNotification(notificationCenter, CFNotificationName(rawValue: name.rawValue as CFString), nil, nil, true)
    }
}
