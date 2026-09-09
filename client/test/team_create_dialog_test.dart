import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// PC(넓은 화면)에서 "팀 생성하기" 직후에만 나던
/// `'_dependents.isEmpty': is not true` 단언 실패를 재현하기 위한 실험용 테스트.
/// home_screen.dart / team_select_screen.dart / desktop_home_screen.dart의 구조만
/// 최소한으로 흉내낸다(Session 없이).
class _Notifier extends ChangeNotifier {
  bool hasTeam = false;
  void enter() {
    hasTeam = true;
    notifyListeners();
  }
}

class _Root extends StatefulWidget {
  final _Notifier notifier;
  const _Root(this.notifier);

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.notifier,
      builder: (context, _) {
        if (!widget.notifier.hasTeam) {
          return _SelectScreen(widget.notifier);
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 700;
            return isWide ? const _DesktopScreen() : const _MobileScreen();
          },
        );
      },
    );
  }
}

/// team_select_screen.dart 흉내.
class _SelectScreen extends StatefulWidget {
  final _Notifier notifier;
  const _SelectScreen(this.notifier);

  @override
  State<_SelectScreen> createState() => _SelectScreenState();
}

class _SelectScreenState extends State<_SelectScreen> {
  bool _creating = false;

  Future<void> _createTeam() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateTeamDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _creating = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30)); // 서버 왕복
      if (mounted) widget.notifier.enter();
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TeamTalk'),
        actions: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(radius: 14),
                SizedBox(width: 8),
                Text('나'),
              ],
            ),
          ),
          PopupMenuButton<void>(
            icon: const Icon(Icons.menu),
            tooltip: '설정',
            itemBuilder: (context) => const [
              PopupMenuItem<void>(child: Text('로그아웃')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.notifier,
        builder: (context, _) {
          final isWide = MediaQuery.sizeOf(context).width >= 700;
          final list = SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              vertical: 32,
              horizontal: isWide ? 0 : 12,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('팀 리스트'),
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Expanded(child: Text('PST')),
                              OutlinedButton(
                                onPressed: () {},
                                child: const Text('설정'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: widget.notifier.enter,
                                child: const Text('팀으로 가기'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Material(
                    child: InkWell(
                      onTap: _creating ? null : _createTeam,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(child: Text('팀 생성하기')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          return isWide
              ? Center(child: list)
              : Align(alignment: Alignment.topCenter, child: list);
        },
      ),
    );
  }
}

/// team_select_screen.dart의 _CreateTeamDialog와 같은 구조 — 컨트롤러를 State가 소유한다.
/// 이걸 다시 "메서드 안에서 만들고 await showDialog 직후 dispose"하는 형태로 되돌리면
/// 아래 테스트가 실패한다(그게 이 테스트가 지키려는 회귀다).
class _CreateTeamDialog extends StatefulWidget {
  const _CreateTeamDialog();

  @override
  State<_CreateTeamDialog> createState() => _CreateTeamDialogState();
}

class _CreateTeamDialogState extends State<_CreateTeamDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('팀 생성하기'),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            labelText: '팀 이름',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('만들기')),
      ],
    );
  }
}

/// desktop_home_screen.dart 흉내(AppBar 없이 Scaffold body 안에 자체 상단바).
class _DesktopScreen extends StatelessWidget {
  const _DesktopScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: PopupMenuButton<void>(
                      tooltip: '팀 전환',
                      itemBuilder: (context) => const [
                        PopupMenuItem<void>(child: Text('PST')),
                      ],
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [Text('PST'), Icon(Icons.expand_more)],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.people_outline),
                  tooltip: '멤버',
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '검색',
                  onPressed: () {},
                ),
                PopupMenuButton<void>(
                  icon: const Icon(Icons.apps),
                  tooltip: '메뉴',
                  itemBuilder: (context) => const [
                    PopupMenuItem<void>(child: Text('파일')),
                  ],
                ),
                PopupMenuButton<void>(
                  icon: const Icon(Icons.menu),
                  tooltip: '설정',
                  itemBuilder: (context) => const [
                    PopupMenuItem<void>(child: Text('로그아웃')),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const Expanded(
            child: Row(
              children: [
                SizedBox(width: 280, child: Center(child: Text('사이드바'))),
                VerticalDivider(width: 1),
                Expanded(child: Center(child: Text('채팅을 선택하세요'))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// room_list_screen.dart 흉내.
class _MobileScreen extends StatelessWidget {
  const _MobileScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: PopupMenuButton<void>(
          tooltip: '팀 전환',
          itemBuilder: (context) => const [
            PopupMenuItem<void>(child: Text('PST')),
          ],
          child: const Text('PST'),
        ),
      ),
      body: const Center(child: Text('토픽')),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.tag), label: '토픽'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: '더보기'),
        ],
      ),
    );
  }
}

Future<void> _runCreateTeamFlow(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final notifier = _Notifier();
  addTearDown(notifier.dispose);
  await tester.pumpWidget(MaterialApp(home: _Root(notifier)));

  await tester.tap(find.text('팀 생성하기'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField), '새 팀');
  await tester.pump();

  await tester.tap(find.text('만들기'));
  // 다이얼로그 닫힘 전환 + 가짜 서버 왕복 + 화면 교체까지 전부 흘려보낸다.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('PC(넓은 화면)에서 팀 생성 후 화면 전환', (tester) async {
    await _runCreateTeamFlow(tester, const Size(1400, 900));
    expect(tester.takeException(), isNull);
    expect(find.text('채팅을 선택하세요'), findsOneWidget);
  });

  testWidgets('안드로이드(좁은 화면)에서 팀 생성 후 화면 전환', (tester) async {
    await _runCreateTeamFlow(tester, const Size(420, 900));
    expect(tester.takeException(), isNull);
    expect(find.text('토픽'), findsWidgets);
  });
}
