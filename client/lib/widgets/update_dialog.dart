import 'package:flutter/material.dart';

import '../services/session.dart';
import '../l10n/tr.dart';

/// "새 버전이 있습니다" 대화상자. 기존엔 MaterialBanner(화면 위쪽 얇은 줄)로만 알려서
/// 놓치기 쉬웠던 걸, 눈에 잘 띄는 모달 대화상자로 바꿨다. "다운로드"(브라우저로 넘겨서
/// 사용자가 직접 받은 파일을 실행해야 했던 방식) 대신 "지금 설치"만 누르면 앱이 파일을
/// 받아서 바로 실행/설치까지 이어간다 — session.installUpdate() 참고.
///
/// session은 ChangeNotifier라 ListenableBuilder로 감싸서, 다운로드 진행률이 바뀔 때마다
/// (installUpdate 안에서 notifyListeners) 이 다이얼로그 내용만 다시 그린다.
class UpdateDialog extends StatelessWidget {
  final Session session;
  final String version;
  const UpdateDialog({super.key, required this.session, required this.version});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final downloading = session.updateDownloading;
        final progress = session.updateDownloadProgress;
        final error = session.updateError;
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.system_update_outlined),
              SizedBox(width: 8),
              Text(tr('업데이트 안내')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('새 버전(v{version})이 있습니다.', {'version': version})),
              if (downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text(
                  progress != null
                      ? tr('다운로드 중... {p0}%', {'p0': (progress * 100).round()})
                      : tr('다운로드 중...'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (!downloading && error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: downloading ? null : () => Navigator.of(context).pop(),
              child: Text(tr('나중에')),
            ),
            FilledButton(
              onPressed: downloading
                  ? null
                  : () async {
                      await session.installUpdate();
                      // 성공하면(에러 없이 끝나면) 설치 프로그램/패키지 설치 화면이 이미
                      // 떴을 테니 이 대화상자는 자동으로 닫는다. 실패했으면 에러 메시지를
                      // 보여줘야 하니 열어둔 채로 다시 시도할 수 있게 둔다.
                      if (context.mounted && session.updateError == null) {
                        Navigator.of(context).pop();
                      }
                    },
              child: downloading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(tr('지금 설치')),
            ),
          ],
        );
      },
    );
  }
}
