package com.teamtalk.messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 앱이 꺼져 있는 동안 온 채팅 푸시(FCM)로 홈 화면 위젯 "안 읽은 대화"의 숫자를 올린다. FCM 플러그인(FlutterFirebaseMessagingReceiver)과
 * 같은 방송(com.google.android.c2dm.intent.RECEIVE)을 따로 받아 data 칸(인텐트 extras)만 읽는다 — 앱(Dart)을 깨우지 않아 빠르고, 플러그인의
 * 알림 그리기는 그대로다. 서버가 안 읽은 수에 드는 푸시에만 unreadDelta를 싣는다(server/src/pushReplyRules.js — 메시지·댓글·멘션).
 * 위젯이 가진 것은 방 세 개뿐이라 그 밖의 방이 올라오면 그 방의 수는 이번에 온 것부터 센다 — 앱을 열면 앱이 정확한 내용으로 다시 넘긴다
 * (home_widget_bridge.dart). 다른 기기에서 읽은 것도 앱을 열 때 맞춰진다.
 */
class PushWidgetReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        val delta = extras.getString("unreadDelta")?.toIntOrNull() ?: return
        if (delta <= 0) return
        val roomId = extras.getString("roomId") ?: return
        UnreadWidgetProvider.bump(
            context,
            roomId,
            extras.getString("widgetName") ?: "",
            extras.getString("isSecret") == "true",
            delta,
        )
    }
}
