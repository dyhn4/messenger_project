import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import '../l10n/tr.dart';

/// 공유할 화면/창을 고르는 대화상자(Windows 전용). Android는 OS가 자체 선택 화면을 띄우므로
/// 이 대화상자를 쓰지 않는다.
///
/// 고른 소스의 id를 돌려준다(취소하면 null) — call_controller.dart의 toggleScreenShare가
/// 그 id로 LiveKit에 "이 창을 공유해라"라고 알려준다.
Future<String?> showScreenSharePicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _ScreenSharePickerDialog(),
  );
}

class _ScreenSharePickerDialog extends StatefulWidget {
  const _ScreenSharePickerDialog();

  @override
  State<_ScreenSharePickerDialog> createState() =>
      _ScreenSharePickerDialogState();
}

class _ScreenSharePickerDialogState extends State<_ScreenSharePickerDialog> {
  List<rtc.DesktopCapturerSource>? _sources;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sources = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen, rtc.SourceType.Window],
      );
      if (mounted) setState(() => _sources = sources);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('공유할 화면 선택')),
      content: SizedBox(
        width: 560,
        height: 420,
        child: switch ((_error, _sources)) {
          (final String error, _) when error.isNotEmpty => Center(
            child: Text(tr('화면 목록을 가져오지 못했습니다: {error}', {'error': error})),
          ),
          (_, null) => const Center(child: CircularProgressIndicator()),
          (_, final List<rtc.DesktopCapturerSource> sources)
              when sources.isEmpty =>
            Center(child: Text(tr('공유할 수 있는 화면이 없습니다.'))),
          (_, final List<rtc.DesktopCapturerSource> sources) =>
            GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 4 / 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: sources.length,
              itemBuilder: (context, i) => _SourceTile(
                source: sources[i],
                onTap: () => Navigator.of(context).pop(sources[i].id),
              ),
            ),
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  final rtc.DesktopCapturerSource source;
  final VoidCallback onTap;
  const _SourceTile({required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final thumbnail = source.thumbnail;
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: thumbnail == null
                  ? const Icon(Icons.desktop_windows_outlined)
                  : Image.memory(thumbnail, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            source.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
