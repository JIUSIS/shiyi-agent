import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/group_chat.dart';
import 'package:shiyi_agent_app/widgets/bagua_icon.dart';
import 'package:shiyi_agent_app/widgets/group_room_tile.dart';

void main() {
  testWidgets('八卦徽章和单色图标都能画出来', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              BaguaAvatar(size: 36),
              BaguaIcon(size: 18, color: Color(0xFF0A84FF)),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(BaguaAvatar), findsOneWidget);
    expect(find.byType(BaguaIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('群聊卡用八卦头像，不再叠双人图标', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupRoomTile(
            room: GroupRoom(
              id: 'g1',
              title: '写作组',
              createdAt: 1,
              updatedAt: 1,
              agents: [
                GroupAgent(id: 'a1', roomId: 'g1', name: '主编'),
                GroupAgent(id: 'a2', roomId: 'g1', name: '写手'),
              ],
            ),
            onTap: () {},
            onEdit: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
    expect(find.byType(BaguaIcon), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.person_2_fill), findsNothing);
    expect(find.byIcon(CupertinoIcons.person_2), findsNothing);
    expect(find.text('写作组'), findsOneWidget);
  });
}
