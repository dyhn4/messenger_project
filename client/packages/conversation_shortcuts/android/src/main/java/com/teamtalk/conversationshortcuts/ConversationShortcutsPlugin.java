package com.teamtalk.conversationshortcuts;

import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.app.Person;
import androidx.core.content.pm.ShortcutInfoCompat;
import androidx.core.content.pm.ShortcutManagerCompat;
import androidx.core.graphics.drawable.IconCompat;

import java.util.Collections;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 알림이 안드로이드의 "대화(conversation)" 레이아웃(프로필 사진이 왼쪽 큰 원 + 앱 아이콘이
 * 모서리 배지)으로 보이게 하려면, 알림의 shortcutId와 같은 id의 long-lived 단축키가 등록돼
 * 있어야 한다. 이 플러그인은 그 단축키를 등록/갱신하기만 한다.
 */
public class ConversationShortcutsPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler {

  private static final String CHANNEL = "teamtalk/conversation_shortcuts";
  /** ShortcutInfo.SHORTCUT_CATEGORY_CONVERSATION (API 30+에만 상수로 존재해서 문자열로 둔다). */
  private static final String CATEGORY_CONVERSATION = "android.shortcut.conversation";

  private MethodChannel channel;
  private Context context;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
    context = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if (!"pushConversationShortcut".equals(call.method)) {
      result.notImplemented();
      return;
    }

    final String id = call.argument("id");
    final String label = call.argument("label");
    final byte[] icon = call.argument("icon");
    if (context == null || id == null || id.isEmpty() || label == null) {
      result.error("bad_args", "id/label이 필요합니다.", null);
      return;
    }

    try {
      // 단축키는 실행 가능한 Intent(action이 있는)를 반드시 가져야 한다 — 런처의 앱 아이콘을
      // 길게 눌렀을 때 뜨는 그 실행 Intent를 그대로 쓴다(ACTION_MAIN이라 조건 충족).
      Intent intent =
          context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
      if (intent == null) {
        intent = new Intent(Intent.ACTION_MAIN);
        intent.setPackage(context.getPackageName());
      }
      intent.putExtra("roomId", id);

      Person.Builder person = new Person.Builder().setName(label).setKey(id).setImportant(true);

      ShortcutInfoCompat.Builder shortcut =
          new ShortcutInfoCompat.Builder(context, id)
              .setShortLabel(label)
              .setLongLabel(label)
              .setIntent(intent)
              // 알림이 참조할 수 있으려면(캐시된 단축키) 반드시 long-lived여야 한다.
              .setLongLived(true)
              .setCategories(Collections.singleton(CATEGORY_CONVERSATION));

      if (icon != null && icon.length > 0) {
        Bitmap bitmap = BitmapFactory.decodeByteArray(icon, 0, icon.length);
        if (bitmap != null) {
          // createWithAdaptiveBitmap을 쓰면 안 된다 — 그건 배경+전경 레이어가 캔버스 전체를
          // 불투명하게 채우는 진짜 어댑티브 아이콘용이라, 우리 아바타처럼 가장자리가 투명한
          // 원형 이미지를 넘기면 시스템이 그 투명 영역 뒤에 자체 배경(어두운 테마에서 검은
          // 테두리로 보임)을 채워 넣는다. 우리 아바타는 이미 원형이라 그냥 일반 비트맵
          // 아이콘으로 넘기면(원형 크롭은 알림 시스템이 알아서 해준다) 테두리 없이 깔끔하다.
          IconCompat compat = IconCompat.createWithBitmap(bitmap);
          shortcut.setIcon(compat);
          person.setIcon(compat);
        }
      }

      shortcut.setPerson(person.build());
      ShortcutManagerCompat.pushDynamicShortcut(context, shortcut.build());
      result.success(true);
    } catch (Exception e) {
      Log.e("ConvShortcuts", "push failed for id=" + id, e);
      result.error("shortcut_failed", e.getMessage(), null);
    }
  }
}
