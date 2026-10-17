package com.teamtalk.messenger

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * 홈 화면 위젯 "안 읽은 대화" — 안 읽은 메시지 합계와 안 읽은 대화방 세 개(이름·수). 앱이 목록이 바뀔 때마다 내용(JSON)을 넘겨
 * 저장하고([save] — home_widget_bridge.dart의 tangotalk/widget 채널) 이 위젯들을 다시 그린다. 방을 누르면 그 방으로, 나머지를 누르면
 * 앱을 연다. 앱 잠금을 켰거나 로그아웃했으면 방 이름 없이 합계만(또는 안내만) 보인다 — 홈 화면은 누구나 볼 수 있다.
 */
class UnreadWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, render(context))
    }

    companion object {
        const val ACTION_OPEN_ROOM = "com.teamtalk.messenger.OPEN_ROOM"
        const val EXTRA_ROOM_ID = "roomId"
        private const val PREFS = "tangotalk_widget"
        private const val KEY = "state"
        private val ROW_IDS = intArrayOf(R.id.widget_row1, R.id.widget_row2, R.id.widget_row3)
        private val NAME_IDS = intArrayOf(R.id.widget_row1_name, R.id.widget_row2_name, R.id.widget_row3_name)
        private val COUNT_IDS = intArrayOf(R.id.widget_row1_count, R.id.widget_row2_count, R.id.widget_row3_count)

        /** 앱이 넘긴 내용을 저장하고 홈 화면의 이 위젯들을 다시 그린다. */
        fun save(context: Context, json: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json).apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, UnreadWidgetProvider::class.java))
            for (id in ids) manager.updateAppWidget(id, render(context))
        }

        private fun openAppIntent(context: Context, requestCode: Int, roomId: String?): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (roomId != null) {
                    action = ACTION_OPEN_ROOM
                    putExtra(EXTRA_ROOM_ID, roomId)
                }
            }
            return PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun render(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.unread_widget)
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, 0, null))
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
            val state = try {
                if (raw == null) null else JSONObject(raw)
            } catch (_: Exception) {
                null
            }
            val signedIn = state != null && !state.optBoolean("loggedOut", false)
            val total = state?.optInt("total", 0) ?: 0
            views.setTextViewText(
                R.id.widget_total,
                if (!signedIn) "" else if (total > 99) "99+" else total.toString(),
            )
            views.setViewVisibility(R.id.widget_total, if (signedIn && total > 0) View.VISIBLE else View.GONE)
            val rooms = state?.optJSONArray("rooms")
            val locked = state?.optBoolean("locked", false) ?: false
            val shown = if (!signedIn || locked || rooms == null) 0 else minOf(rooms.length(), ROW_IDS.size)
            for (i in ROW_IDS.indices) {
                if (i < shown) {
                    val room = rooms!!.getJSONObject(i)
                    val unread = room.optInt("unread", 0)
                    views.setViewVisibility(ROW_IDS[i], View.VISIBLE)
                    views.setTextViewText(NAME_IDS[i], room.optString("name", ""))
                    views.setTextViewText(COUNT_IDS[i], if (unread > 99) "99+" else unread.toString())
                    views.setOnClickPendingIntent(ROW_IDS[i], openAppIntent(context, i + 1, room.optString("id")))
                } else {
                    views.setViewVisibility(ROW_IDS[i], View.GONE)
                }
            }
            val empty = when {
                !signedIn -> "로그인하면 안 읽은 대화가 여기에 보입니다."
                locked && total > 0 -> "안 읽은 메시지 ${if (total > 99) "99+" else total}개 — 앱 잠금 중이라 방 이름은 숨깁니다."
                shown == 0 -> "새 메시지가 없습니다."
                else -> null
            }
            views.setViewVisibility(R.id.widget_empty, if (empty == null) View.GONE else View.VISIBLE)
            if (empty != null) views.setTextViewText(R.id.widget_empty, empty)
            return views
        }
    }
}
