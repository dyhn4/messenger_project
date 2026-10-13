import 'package:client/services/password_ime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀번호 칸 감지(PasswordIme.isPasswordField) — 포커스가 obscureText 칸에 있을 때만 한글 입력기를 끈다.
void main() {
  testWidgets('비밀번호 칸에 포커스가 있을 때만 참이다', (tester) async {
    final id = FocusNode();
    final password = FocusNode();
    final button = FocusNode();
    addTearDown(id.dispose);
    addTearDown(password.dispose);
    addTearDown(button.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: id),
              TextField(focusNode: password, obscureText: true),
              TextButton(
                focusNode: button,
                onPressed: () {},
                child: const Text('로그인'),
              ),
            ],
          ),
        ),
      ),
    );

    bool focusedIsPassword() =>
        PasswordIme.isPasswordField(FocusManager.instance.primaryFocus);

    id.requestFocus();
    await tester.pump();
    expect(focusedIsPassword(), isFalse);

    password.requestFocus();
    await tester.pump();
    expect(focusedIsPassword(), isTrue);

    button.requestFocus();
    await tester.pump();
    expect(focusedIsPassword(), isFalse);

    password.unfocus();
    await tester.pump();
    expect(focusedIsPassword(), isFalse);
    expect(PasswordIme.isPasswordField(null), isFalse);
  });
}
