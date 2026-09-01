import 'package:sqflite/sqflite.dart';

import '../core/group_chat.dart';
import 'db.dart';

class GroupChatStore {
  GroupChatStore._();
  static final GroupChatStore instance = GroupChatStore._();

  static Future<void> ensureTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_rooms (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_agents (
        id TEXT PRIMARY KEY,
        room_id TEXT NOT NULL,
        name TEXT NOT NULL,
        persona TEXT NOT NULL DEFAULT '',
        api_profile_id TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        reports_to TEXT NOT NULL DEFAULT '',
        color INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_messages (
        id TEXT PRIMARY KEY,
        room_id TEXT NOT NULL,
        role TEXT NOT NULL,
        agent_id TEXT,
        content TEXT NOT NULL DEFAULT '',
        reasoning TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_agent_summaries (
        room_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (room_id, agent_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_group_agents_room ON group_agents(room_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_group_messages_room ON group_messages(room_id, created_at)',
    );
    await ensureAgentOrgColumns(db);
    await ensureGroupRoomProjectColumn(db);
  }

  static Future<void> ensureGroupRoomProjectColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(group_rooms)');
    final names = {for (final col in cols) '${col['name']}'};
    if (!names.contains('project_id')) {
      await db.execute(
        "ALTER TABLE group_rooms ADD COLUMN project_id TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  static Future<void> ensureAgentOrgColumns(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(group_agents)');
    final names = {for (final col in cols) '${col['name']}'};
    if (!names.contains('title')) {
      await db.execute(
        "ALTER TABLE group_agents ADD COLUMN title TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!names.contains('reports_to')) {
      await db.execute(
        "ALTER TABLE group_agents ADD COLUMN reports_to TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  Future<List<GroupRoom>> listRooms() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'group_rooms',
      orderBy: 'sort_order ASC, updated_at DESC',
    );
    final rooms = [for (final row in rows) GroupRoom.fromMap(row)];
    if (rooms.isEmpty) return rooms;
    final agents = await db.query('group_agents', orderBy: 'sort_order ASC');
    final byRoom = <String, List<GroupAgent>>{};
    for (final row in agents) {
      final agent = GroupAgent.fromMap(row);
      (byRoom[agent.roomId] ??= []).add(agent);
    }
    final lastRows = await db.rawQuery('''
      SELECT room_id, content FROM group_messages
      WHERE created_at IN (
        SELECT MAX(created_at) FROM group_messages GROUP BY room_id
      )
    ''');
    final lastByRoom = <String, String>{
      for (final row in lastRows)
        '${row['room_id']}': '${row['content'] ?? ''}',
    };
    for (final room in rooms) {
      room.agents = byRoom[room.id] ?? const [];
      room.lastMessage = lastByRoom[room.id] ?? '';
    }
    return rooms;
  }

  /// 把群聊移到某个项目文件夹（null / 空字符串 = 未分类）。
  Future<void> setRoomProject(String id, String? projectId) async {
    final db = await AppDatabase.instance.db;
    await db.update(
      'group_rooms',
      {'project_id': projectId ?? ''},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 按给定 id 顺序写入群聊 sort_order（下标即顺序）。
  Future<void> reorderRooms(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      for (var i = 0; i < ids.length; i++) {
        await txn.update(
          'group_rooms',
          {'sort_order': i + 1},
          where: 'id = ?',
          whereArgs: [ids[i]],
        );
      }
    });
  }

  Future<int> roomCount() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM group_rooms');
    return int.tryParse('${rows.first['c']}') ?? 0;
  }

  Future<GroupRoom?> getRoom(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'group_rooms',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final room = GroupRoom.fromMap(rows.first);
    room.agents = await listAgents(id);
    return room;
  }

  Future<List<GroupAgent>> listAgents(String roomId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'group_agents',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'sort_order ASC',
    );
    return [for (final row in rows) GroupAgent.fromMap(row)];
  }

  Future<List<GroupMessage>> listMessages(String roomId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'group_messages',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'created_at ASC',
    );
    return [for (final row in rows) GroupMessage.fromMap(row)];
  }

  Future<void> upsertRoom(GroupRoom room) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'group_rooms',
      room.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveAgents(String roomId, List<GroupAgent> agents) async {
    final db = await AppDatabase.instance.db;
    await db.delete('group_agents', where: 'room_id = ?', whereArgs: [roomId]);
    final sanitized = groupChatSanitizeOrg(agents);
    for (var i = 0; i < sanitized.length; i++) {
      final agent = sanitized[i].copyWith(sortOrder: i);
      await db.insert('group_agents', agent.toMap());
    }
  }

  Future<void> insertMessage(GroupMessage message) async {
    final db = await AppDatabase.instance.db;
    await db.insert('group_messages', message.toMap());
    await db.update(
      'group_rooms',
      {'updated_at': message.createdAt},
      where: 'id = ?',
      whereArgs: [message.roomId],
    );
  }

  Future<void> updateMessage(GroupMessage message) async {
    final db = await AppDatabase.instance.db;
    await db.update(
      'group_messages',
      message.toMap(),
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }

  Future<String> getSummary(String roomId, String agentId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'group_agent_summaries',
      columns: ['summary'],
      where: 'room_id = ? AND agent_id = ?',
      whereArgs: [roomId, agentId],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return (rows.first['summary'] ?? '').toString();
  }

  Future<void> saveSummary(
    String roomId,
    String agentId,
    String summary,
  ) async {
    final db = await AppDatabase.instance.db;
    await db.insert('group_agent_summaries', {
      'room_id': roomId,
      'agent_id': agentId,
      'summary': summary,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMessage(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('group_messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteRoom(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete(
      'group_agent_summaries',
      where: 'room_id = ?',
      whereArgs: [id],
    );
    await db.delete('group_messages', where: 'room_id = ?', whereArgs: [id]);
    await db.delete('group_agents', where: 'room_id = ?', whereArgs: [id]);
    await db.delete('group_rooms', where: 'id = ?', whereArgs: [id]);
  }
}
