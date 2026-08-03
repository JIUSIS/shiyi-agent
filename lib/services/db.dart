import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

class AppDatabase {
  static final AppDatabase _instance = AppDatabase._();
  AppDatabase._();
  static AppDatabase get instance => _instance;

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      join(dir.path, 'shiyi_agent.db'),
      version: 7,
      onCreate: _createBaseTables,
      onUpgrade: _upgrade,
    );
    return _db!;
  }

Future<void> _createBaseTables(Database db, int version) async {
  await db.execute('''
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      model TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      total_tokens INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      role TEXT NOT NULL,
      content TEXT,
      tool_calls TEXT,
      tool_call_id TEXT,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('CREATE INDEX idx_messages_session ON messages(session_id)');
  await db.execute('''
    CREATE TABLE memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL,
      source TEXT,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE skills (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      description TEXT,
      content TEXT,
      files TEXT,
      large_files TEXT,
      dir_path TEXT,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE tool_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      name TEXT NOT NULL,
      args_summary TEXT,
      summary TEXT,
      ok INTEGER,
      started_at INTEGER NOT NULL,
      finished_at INTEGER
    )
  ''');
  await db.execute('CREATE INDEX idx_tool_events_session ON tool_events(session_id)');
}

Future<void> _upgrade(Database db, int oldV, int newV) async {
  // v2 -> v3：skills 表加 files 列（辅助文件树）。
  if (oldV < 3) {
    final cols = await db.rawQuery('PRAGMA table_info(skills)');
    if (!cols.any((c) => c['name'] == 'files')) {
      await db.execute('ALTER TABLE skills ADD COLUMN files TEXT');
    }
  }
  // v3 -> v4：skills 表加大文件清单与磁盘目录列。
  if (oldV < 4) {
    final cols = await db.rawQuery('PRAGMA table_info(skills)');
    if (!cols.any((c) => c['name'] == 'large_files')) {
      await db.execute('ALTER TABLE skills ADD COLUMN large_files TEXT');
    }
    if (!cols.any((c) => c['name'] == 'dir_path')) {
      await db.execute('ALTER TABLE skills ADD COLUMN dir_path TEXT');
    }
  }
  // v4 -> v5：清理把超大内容塞进 DB 的旧技能行（单行超过 CursorWindow 会让 app 打不开）。
  if (oldV < 5) {
    await _pruneOversizedSkills(db);
  }
  // v5 -> v6：新增 tool_events 表（会话工具执行历史）。
  if (oldV < 6) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tool_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        name TEXT NOT NULL,
        args_summary TEXT,
        summary TEXT,
        ok INTEGER,
        started_at INTEGER NOT NULL,
        finished_at INTEGER
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tool_events_session ON tool_events(session_id)');
  }
  // v6 -> v7：sessions 表加 total_tokens 列（累计本次会话消耗的 token）。
  if (oldV < 7) {
    final cols = await db.rawQuery('PRAGMA table_info(sessions)');
    if (!cols.any((c) => c['name'] == 'total_tokens')) {
      await db.execute('ALTER TABLE sessions ADD COLUMN total_tokens INTEGER NOT NULL DEFAULT 0');
    }
  }
}

/// 删除把超大内容塞进单行的技能（>800KB），避免 CursorWindow 溢出。
Future<void> _pruneOversizedSkills(Database db) async {
  await db.execute('''
    DELETE FROM skills WHERE
      length(content) > 800000 OR
      length(description) > 800000 OR
      length(files) > 800000 OR
      length(large_files) > 800000
  ''');
}

  // ---- sessions ----
  Future<List<Session>> listSessions() async {
    final db = await this.db;
    final rows = await db.rawQuery('''
      SELECT s.*, (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS message_count
      FROM sessions s ORDER BY s.updated_at DESC
    ''');
    return rows.map(Session.fromMap).toList();
  }

  Future<Session?> getSession(String id) async {
    final db = await this.db;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final s = Session.fromMap(rows.first);
    final c = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM messages WHERE session_id = ?', [id]),
    );
    s.messageCount = c ?? 0;
    return s;
  }

  Future<void> upsertSession(Session s) async {
    final db = await this.db;
    await db.insert('sessions', s.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateSessionTokens(String id, int tokens) async {
    final db = await this.db;
    await db.update('sessions', {'total_tokens': tokens}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> touchSession(String id, {String? title, String? model}) async {
    final db = await this.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, dynamic>{'updated_at': now};
    if (title != null) updates['title'] = title;
    if (model != null) updates['model'] = model;
    await db.update('sessions', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> renameSession(String id, String title) async {
    final db = await this.db;
    await db.update('sessions', {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteSession(String id) async {
    final db = await this.db;
    await db.delete('messages', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('tool_events', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// 按标题或消息内容搜索会话，返回每个会话及一段命中内容片段。
  Future<List<SessionSearchResult>> searchSessions(String query) async {
    final db = await this.db;
    final like = '%$query%';
    final rows = await db.rawQuery('''
      SELECT DISTINCT s.*,
             (SELECT COUNT(*) FROM messages m2 WHERE m2.session_id = s.id) AS message_count
      FROM sessions s
      LEFT JOIN messages m ON m.session_id = s.id
      WHERE s.title LIKE ? OR m.content LIKE ?
      ORDER BY s.updated_at DESC
    ''', [like, like]);
    final out = <SessionSearchResult>[];
    for (final r in rows) {
      final s = Session.fromMap(r);
      var snippet = '';
      final ms = await db.query('messages',
          where: 'session_id = ? AND content LIKE ?',
          whereArgs: [s.id, like],
          orderBy: 'created_at DESC',
          limit: 1);
      if (ms.isNotEmpty) {
        final content =
            (ms.first['content'] as String? ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (content.isNotEmpty) snippet = _snippetAround(content, query);
      }
      out.add(SessionSearchResult(session: s, snippet: snippet));
    }
    return out;
  }

  String _snippetAround(String content, String query, {int radius = 28}) {
    final idx = content.indexOf(query);
    if (idx < 0) {
      return content.length > 60 ? '${content.substring(0, 60)}…' : content;
    }
    var start = idx - radius;
    if (start < 0) start = 0;
    var end = idx + query.length + radius;
    if (end > content.length) end = content.length;
    return '${start > 0 ? '…' : ''}${content.substring(start, end).trim()}${end < content.length ? '…' : ''}';
  }

  // ---- messages ----
  Future<List<ChatMessage>> listMessages(String sessionId) async {
    final db = await this.db;
    final rows = await db.query('messages',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at ASC');
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> insertMessage(ChatMessage m) async {
    final db = await this.db;
    await db.insert('messages', m.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateMessageContent(String id, String content, {List<ToolCall>? toolCalls}) async {
    final db = await this.db;
    final upd = <String, dynamic>{
      'content': content,
    };
    if (toolCalls != null) {
      upd['tool_calls'] = jsonEncode(toolCalls.map((t) => t.toJson()).toList());
    }
    await db.update('messages', upd, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMessage(String id) async {
    final db = await this.db;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  // ---- memories ----
  Future<int> addMemory(String content, String source) async {
    final db = await this.db;
    return db.insert('memories',
        {'content': content, 'source': source, 'created_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMemory(int id) async {
    final db = await this.db;
    await db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<MemoryEntry>> listMemories() async {
    final db = await this.db;
    final rows = await db.query('memories', orderBy: 'created_at DESC', limit: 200);
    return rows.map(MemoryEntry.fromMap).toList();
  }

  Future<List<MemoryEntry>> searchMemories(String query) async {
    final db = await this.db;
    final rows = await db.query('memories',
        where: 'content LIKE ?', whereArgs: ['%$query%'], orderBy: 'created_at DESC',
        limit: 50);
    return rows.map(MemoryEntry.fromMap).toList();
  }

  Future<List<MemoryEntry>> recentMemoriesWithTerms(List<String> terms, int limit) async {
    final db = await this.db;
    if (terms.isEmpty) return listMemories().then((v) => v.take(8).toList());
    final rows = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final t in terms) {
      final r = await db.query('memories',
          where: 'content LIKE ?', whereArgs: ['%$t%'], orderBy: 'created_at DESC',
          limit: limit);
      for (final row in r) {
        if (seen.add(row['id'] as int)) rows.add(row);
      }
    }
    return rows.map(MemoryEntry.fromMap).toList();
  }

  // ---- skills ----
  Future<int> addSkill(Skill s) async {
    final db = await this.db;
    return db.insert('skills',
        {'name': s.name, 'description': s.description, 'content': s.content, 'files': jsonEncode(s.files), 'large_files': jsonEncode(s.largeFiles), 'dir_path': s.dirPath, 'created_at': s.createdAt},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateSkill(Skill s) async {
    final db = await this.db;
    await db.update('skills',
        {'name': s.name, 'description': s.description, 'content': s.content, 'files': jsonEncode(s.files), 'large_files': jsonEncode(s.largeFiles), 'dir_path': s.dirPath},
        where: 'id = ?', whereArgs: [s.id]);
  }

  Future<void> deleteSkill(int id) async {
    final db = await this.db;
    await db.delete('skills', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Skill>> listSkills() async {
    final db = await this.db;
    await _pruneOversizedSkills(db);
    final rows = await db.query('skills', orderBy: 'created_at DESC');
    return rows.map(Skill.fromMap).toList();
  }

  Future<Skill?> getSkillByName(String name) async {
    final db = await this.db;
    final rows = await db.query('skills', where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : Skill.fromMap(rows.first);
  }

  // ---- tool events ----
  Future<int> addToolEvent(String sessionId, ToolEvent ev) async {
    final db = await this.db;
    return db.insert('tool_events',
        {
          'session_id': sessionId,
          'name': ev.name,
          'args_summary': ev.argsSummary,
          'summary': ev.summary,
          'ok': ev.ok ? 1 : 0,
          'started_at': ev.startedAt,
          'finished_at': ev.finishedAt,
        });
  }

  Future<void> updateToolEvent(int id, ToolEvent ev) async {
    final db = await this.db;
    await db.update('tool_events',
        {
          'summary': ev.summary,
          'ok': ev.ok ? 1 : 0,
          'finished_at': ev.finishedAt,
        },
        where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ToolEvent>> listToolEvents(String sessionId) async {
    final db = await this.db;
    final rows = await db.query('tool_events',
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'started_at ASC');
    return rows.map(ToolEvent.fromMap).toList();
  }

  /// 批量删除消息（上下文压缩时清理被摘要覆盖的旧消息）。
  Future<void> deleteMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await this.db;
    final marks = List.filled(ids.length, '?').join(',');
    await db.delete('messages', where: 'id IN ($marks)', whereArgs: ids);
  }
}
