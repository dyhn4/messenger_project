import 'package:client/services/typing_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final gate = TypingGate.instance;
  tearDown(gate.reset);

  testWidgets('조합 중이 아니면 알림을 바로 내보낸다', (tester) async {
    var n = 0;
    gate.run(Object(), () => n++);
    expect(n, 1);
    expect(gate.holding, isFalse);
  });

  testWidgets('조합하는 동안에는 모았다가, 손을 멈추면 한 번에 내보낸다(같은 대상은 한 번만)', (tester) async {
    final session = Object(), room = Object();
    var sessionNotified = 0, roomNotified = 0;

    gate.composing();
    expect(gate.holding, isTrue);
    for (var i = 0; i < 5; i++) {
      gate.run(session, () => sessionNotified++);
    }
    gate.run(room, () => roomNotified++);
    expect(sessionNotified, 0);
    expect(roomNotified, 0);

    // 계속 치는 동안(0.4초 안에 다음 조합)은 미뤄진다.
    await tester.pump(const Duration(milliseconds: 300));
    gate.composing();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sessionNotified, 0);

    // 손을 멈추면 대상마다 한 번씩만.
    await tester.pump(TypingGate.pause);
    expect(sessionNotified, 1);
    expect(roomNotified, 1);
    expect(gate.holding, isFalse);
  });

  testWidgets('메시지를 보내면(flush) 바로 내보낸다', (tester) async {
    var n = 0;
    gate.composing();
    gate.run(Object(), () => n++);
    expect(n, 0);
    gate.flush();
    expect(n, 1);
    expect(gate.holding, isFalse);
  });

  testWidgets('dispose된 대상의 알림은 버린다', (tester) async {
    final owner = Object();
    var n = 0;
    gate.composing();
    gate.run(owner, () => n++);
    gate.cancel(owner);
    await tester.pump(TypingGate.pause);
    expect(n, 0);
  });

  testWidgets('조합이 확정돼도 오래 모은 게 아니면 계속 모은다', (tester) async {
    var n = 0;
    gate.composing();
    gate.run(Object(), () => n++);
    gate.committed(); // 방금 시작했으니 maxHold 전
    expect(n, 0);
    expect(gate.holding, isTrue);
    await tester.pump(TypingGate.pause);
    expect(n, 1);
  });
}
