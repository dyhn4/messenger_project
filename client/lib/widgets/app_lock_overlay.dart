import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/api_client.dart' show ApiException;
import '../services/app_lock.dart';
import '../services/session.dart';
import '../l10n/tr.dart';

/// 앱 전체(모든 화면·다이얼로그)를 감싸서, 잠겨 있으면(AppSettings.appLocked — 자동 잠금) 그
/// 위를 잠금 화면으로 덮는다. 잠긴 동안은 아래 화면으로 키보드 포커스가 가지 않고, 마우스도
/// 잠금 화면이 다 받는다. 로그인 전 화면에서는 잠그지 않는다.
class AppLockGate extends StatelessWidget {
  final Session session;
  final Widget child;
  const AppLockGate({super.key, required this.session, required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.settings]),
      builder: (context, _) {
        final locked =
            session.settings.appLocked && session.stage == AuthStage.ready;
        return Stack(
          children: [
            ExcludeFocus(excluding: locked, child: child),
            // 이 자리는 Navigator(와 그 Overlay)보다 위라, 잠금 화면 안의 툴팁·입력칸 메뉴가 쓸
            // Overlay를 따로 둔다.
            if (locked)
              Positioned.fill(
                child: Overlay.wrap(child: AppLockScreen(session: session)),
              ),
          ],
        );
      },
    );
  }
}

/// 잠금 화면 — "현재 화면 잠금모드입니다." + 비밀번호 입력. 비밀번호는 서버에 확인한다(로그인
/// 비밀번호와 같다). 서버에 닿지 않거나 비밀번호가 생각나지 않으면 로그아웃해서 빠져나갈 수 있다.
class AppLockScreen extends StatefulWidget {
  final Session session;
  const AppLockScreen({super.key, required this.session});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final password = _password.text;
    if (password.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.api!.verifyPassword(password);
      _password.clear();
      await AppLock.unlock(widget.session);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr('서버에 연결하지 못했습니다. 연결 상태를 확인해 주세요.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _password.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _password.text.length,
        );
        _focus.requestFocus();
      }
    }
  }

  Future<void> _logout() async {
    await AppLock.unlock(widget.session);
    await widget.session.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      // 뒤의 대화 내용이 읽히지 않게 흐리게 한 뒤 회색으로 덮는다.
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            color: const Color(0xCC5A5A5A),
            alignment: Alignment.center,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock, size: 110, color: Colors.white),
                  const SizedBox(height: 20),
                  Text(
                    tr('현재 화면 잠금모드입니다.\n잠금 해제를 하려면 비밀번호를 입력해주세요.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _password,
                      focusNode: _focus,
                      autofocus: true,
                      obscureText: true,
                      enabled: !_busy,
                      onSubmitted: (_) => _unlock(),
                      style: const TextStyle(color: Colors.black87),
                      decoration: InputDecoration(
                        hintText: tr('비밀번호 입력'),
                        hintStyle: const TextStyle(color: Colors.black38),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.92),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: _busy
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(
                                  Icons.arrow_forward,
                                  color: Colors.black54,
                                ),
                                tooltip: tr('잠금 해제'),
                                onPressed: _unlock,
                              ),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFFD0CC)),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: _busy ? null : _logout,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    child: Text(tr('로그아웃')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
