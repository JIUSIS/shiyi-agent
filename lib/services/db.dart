import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

class AppDatabase {
  static final AppDatabase _instance = AppDatabase._();
  AppDatabase._();
  static AppDatabase get instance => _instance;

  Database? _db;

  /// 首次打开连接的共享 future：并发首次调用只打开一次（见 [db]）。
  Future<Database>? _opening;

  Future<Database> get db {
    final existing = _db;
    if (existing != null) return Future.value(existing);
    // 缓存首次打开的 future：两个并发调用不会各自 openDatabase（双开会
    // 竞争写锁并泄漏一个连接）。
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    try {
      // Windows 桌面端 sqflite 没有原生实现：切换到 FFI（sqlite3.dll）。
      // Android/iOS 继续走默认原生实现。全局 databaseFactory 赋值是幂等的。
      if (Platform.isWindows) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      // Windows 用应用支持目录（%APPDATA%），Android 用 Documents。
      final dir = await (Platform.isWindows
          ? getApplicationSupportDirectory()
          : getApplicationDocumentsDirectory());
      final db = await openDatabase(
        join(dir.path, 'shiyi_agent.db'),
        version: 20,
        onCreate: _createBaseTables,
        onUpgrade: _upgrade,
        onOpen: _repairSchema,
        onConfigure: (db) async {
          // ⚠️ 注意：不能在这里执行返回结果集的 PRAGMA（如 journal_mode=WAL）——
          // Android 原生 sqflite 的 execute() 会抛 "Queries can be performed
          // using SQLiteDatabase query or rawQuery methods only"，导致
          // openDatabase 失败、应用初始化失败（2026-08-14 真机踩坑）。
          // WAL 无需显式开启：sqflite Android 默认已启用。
          // busy_timeout 不返回结果集，用 rawQuery 执行安全。
          await db.rawQuery('PRAGMA busy_timeout=5000');
        },
      );
      _db = db;
      return db;
    } catch (_) {
      // 打开失败：重置共享 future，允许下次调用重试
      //（否则失败的 future 会被永久缓存，本进程内 DB 层彻底失效）。
      _opening = null;
      rethrow;
    }
  }

  Future<void> _createBaseTables(Database db, int version) async {
    await db.execute('''
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      model TEXT,
      api_profile TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      total_tokens INTEGER NOT NULL DEFAULT 0,
      last_usage_total_tokens INTEGER,
      rolling_summary TEXT,
      project_id TEXT,
      workspace_dir TEXT,
      cache_hit_tokens INTEGER NOT NULL DEFAULT 0,
      cache_input_tokens INTEGER NOT NULL DEFAULT 0,
      context_limit INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''');
    await db.execute('''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      role TEXT NOT NULL,
      content TEXT,
      reasoning TEXT,
      subagent_result TEXT,
      tool_calls TEXT,
      tool_call_id TEXT,
      created_at INTEGER NOT NULL,
      archived INTEGER NOT NULL DEFAULT 0
    )
  ''');
    await db.execute(
      'CREATE INDEX idx_messages_session ON messages(session_id)',
    );
    await db.execute('''
    CREATE TABLE memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL,
      source TEXT,
      type TEXT NOT NULL DEFAULT 'user',
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
    await db.execute(
      'CREATE INDEX idx_tool_events_session ON tool_events(session_id)',
    );
    await db.execute('''
    CREATE TABLE projects (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      workspace_dir TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''');
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
        'CREATE INDEX IF NOT EXISTS idx_tool_events_session ON tool_events(session_id)',
      );
    }
    // v6 -> v7：sessions 表加 total_tokens 列（累计本次会话消耗的 token）。
    if (oldV < 7) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'total_tokens')) {
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN total_tokens INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    // v7 -> v8：sessions 表加 workspace_dir 列（会话级项目工作目录）。
    if (oldV < 8) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'workspace_dir')) {
        await db.execute('ALTER TABLE sessions ADD COLUMN workspace_dir TEXT');
      }
    }
    // v8 -> v9：强制补 workspace_dir 列（修复部分 v8 库因 onCreate 漏列而缺列）。
    if (oldV < 9) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'workspace_dir')) {
        await db.execute('ALTER TABLE sessions ADD COLUMN workspace_dir TEXT');
      }
    }
    // v9 -> v10：messages 表加 reasoning 列（模型思考内容）。
    if (oldV < 10) {
      final cols = await db.rawQuery('PRAGMA table_info(messages)');
      if (!cols.any((c) => c['name'] == 'reasoning')) {
        await db.execute('ALTER TABLE messages ADD COLUMN reasoning TEXT');
      }
    }
    // v10 -> v11：memories 表加 type 列（user/feedback/project/reference，默认 user）。
    if (oldV < 11) {
      final cols = await db.rawQuery('PRAGMA table_info(memories)');
      if (!cols.any((c) => c['name'] == 'type')) {
        await db.execute(
          "ALTER TABLE memories ADD COLUMN type TEXT NOT NULL DEFAULT 'user'",
        );
      }
    }
    // v11 -> v12：sessions 表加 last_usage_total_tokens 列
    // （最近一次请求的真实 total_tokens，作为上下文统计基线）。
    if (oldV < 12) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'last_usage_total_tokens')) {
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN last_usage_total_tokens INTEGER',
        );
      }
    }
    // v12 -> v13：messages 加 archived（压缩只归档不删历史），
    // sessions 加 rolling_summary（滚动任务摘要持久化）。
    if (oldV < 13) {
      final msgCols = await db.rawQuery('PRAGMA table_info(messages)');
      if (!msgCols.any((c) => c['name'] == 'archived')) {
        await db.execute(
          'ALTER TABLE messages ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
        );
      }
      final sessionCols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!sessionCols.any((c) => c['name'] == 'rolling_summary')) {
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN rolling_summary TEXT',
        );
      }
    }
    // v13 -> v14：新增 projects 表，sessions 加 project_id（未分类为空）。
    if (oldV < 14) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          workspace_dir TEXT
        )
      ''');
      final sessionCols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!sessionCols.any((c) => c['name'] == 'project_id')) {
        await db.execute('ALTER TABLE sessions ADD COLUMN project_id TEXT');
      }
    }
    // v14 -> v15：projects 表加 workspace_dir（项目级工作目录）。
    if (oldV < 15) {
      final cols = await db.rawQuery('PRAGMA table_info(projects)');
      if (!cols.any((c) => c['name'] == 'workspace_dir')) {
        await db.execute('ALTER TABLE projects ADD COLUMN workspace_dir TEXT');
      }
    }
    // v15 -> v16：sessions 表加缓存命中率累计列
    // （cache_hit_tokens / cache_input_tokens，会话级持久化，
    //  退出会话再进入/重启后仍显示整段会话的缓存命中率）。
    if (oldV < 16) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'cache_hit_tokens')) {
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN cache_hit_tokens INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!cols.any((c) => c['name'] == 'cache_input_tokens')) {
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN cache_input_tokens INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    // v16 -> v17：拾忆子代理原始报告跟随助手消息落库，
    // 用于左侧气泡折叠展示，不进入模型上下文。
    if (oldV < 17) {
      final cols = await db.rawQuery('PRAGMA table_info(messages)');
      if (!cols.any((c) => c['name'] == 'subagent_result')) {
        await db.execute(
          'ALTER TABLE messages ADD COLUMN subagent_result TEXT',
        );
      }
    }
    // v17 -> v18：sessions 加 api_profile（会话绑定的已保存配置名）。
    if (oldV < 18) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'api_profile')) {
        await db.execute('ALTER TABLE sessions ADD COLUMN api_profile TEXT');
      }
    }
    // v18 -> v19：sessions 加 context_limit（0 = 跟随全局新建会话默认）。
    if (oldV < 19) {
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!cols.any((c) => c['name'] == 'context_limit')) {
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN context_limit INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    // v19 -> v20：项目 / 会话主页长按拖拽排序。
    if (oldV < 20) {
      await _ensureSortOrderColumns(db);
    }
  }

  /// 兜底修复：早期/异常创建的库可能在 memories 表漏掉 type 列。
  Future<void> _repairSchema(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(memories)');
    if (!cols.any((c) => c['name'] == 'type')) {
      await db.execute(
        "ALTER TABLE memories ADD COLUMN type TEXT NOT NULL DEFAULT 'user'",
      );
    }
    final sessionCols = await db.rawQuery('PRAGMA table_info(sessions)');
    if (!sessionCols.any((c) => c['name'] == 'last_usage_total_tokens')) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN last_usage_total_tokens INTEGER',
      );
    }
    final messageCols = await db.rawQuery('PRAGMA table_info(messages)');
    if (!messageCols.any((c) => c['name'] == 'archived')) {
      await db.execute(
        'ALTER TABLE messages ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!messageCols.any((c) => c['name'] == 'subagent_result')) {
      await db.execute('ALTER TABLE messages ADD COLUMN subagent_result TEXT');
    }
    if (!sessionCols.any((c) => c['name'] == 'rolling_summary')) {
      await db.execute('ALTER TABLE sessions ADD COLUMN rolling_summary TEXT');
    }
    if (!sessionCols.any((c) => c['name'] == 'project_id')) {
      await db.execute('ALTER TABLE sessions ADD COLUMN project_id TEXT');
    }
    if (!sessionCols.any((c) => c['name'] == 'api_profile')) {
      await db.execute('ALTER TABLE sessions ADD COLUMN api_profile TEXT');
    }
    if (!sessionCols.any((c) => c['name'] == 'context_limit')) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN context_limit INTEGER NOT NULL DEFAULT 0',
      );
    }
    final cacheCols = await db.rawQuery('PRAGMA table_info(sessions)');
    if (!cacheCols.any((c) => c['name'] == 'cache_hit_tokens')) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN cache_hit_tokens INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!cacheCols.any((c) => c['name'] == 'cache_input_tokens')) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN cache_input_tokens INTEGER NOT NULL DEFAULT 0',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        workspace_dir TEXT
      )
    ''');
    final projectCols = await db.rawQuery('PRAGMA table_info(projects)');
    if (!projectCols.any((c) => c['name'] == 'workspace_dir')) {
      await db.execute('ALTER TABLE projects ADD COLUMN workspace_dir TEXT');
    }
    await _ensureSortOrderColumns(db);
  }

  Future<void> _ensureSortOrderColumns(Database db) async {
    final sessionCols = await db.rawQuery('PRAGMA table_info(sessions)');
    if (!sessionCols.any((c) => c['name'] == 'sort_order')) {
      await db.execute(
        'ALTER TABLE sessions ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
      );
    }
    final projectCols = await db.rawQuery('PRAGMA table_info(projects)');
    if (!projectCols.any((c) => c['name'] == 'sort_order')) {
      await db.execute(
        'ALTER TABLE projects ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
      );
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
      FROM sessions s
      ORDER BY s.sort_order ASC, s.updated_at DESC
    ''');
    return rows.map(Session.fromMap).toList();
  }

  Future<Session?> getSession(String id) async {
    final db = await this.db;
    final rows = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final s = Session.fromMap(rows.first);
    final c = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM messages WHERE session_id = ?', [
        id,
      ]),
    );
    s.messageCount = c ?? 0;
    return s;
  }

  Future<void> upsertSession(Session s) async {
    final db = await this.db;
    await db.insert(
      'sessions',
      s.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateSessionTokens(String id, int tokens) async {
    final db = await this.db;
    await db.update(
      'sessions',
      {'total_tokens': tokens},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSessionLastUsage(String id, int? tokens) async {
    final db = await this.db;
    await db.update(
      'sessions',
      {'last_usage_total_tokens': tokens},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 持久化本会话累计的缓存命中率分子/分母
  /// （Σ缓存token / Σ输入token，退出会话再进入/重启后仍可见）。
  Future<void> updateSessionCacheTokens(
    String id,
    int hitTokens,
    int inputTokens,
  ) async {
    final db = await this.db;
    await db.update(
      'sessions',
      {'cache_hit_tokens': hitTokens, 'cache_input_tokens': inputTokens},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSessionRollingSummary(String id, String summary) async {
    final db = await this.db;
    await db.update(
      'sessions',
      {'rolling_summary': summary},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> touchSession(
    String id, {
    String? title,
    String? model,
    String? apiProfile,
    int? contextLimit,
  }) async {
    final db = await this.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, dynamic>{'updated_at': now};
    if (title != null) updates['title'] = title;
    if (model != null) updates['model'] = model;
    if (apiProfile != null) updates['api_profile'] = apiProfile;
    if (contextLimit != null) updates['context_limit'] = contextLimit;
    await db.update('sessions', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> renameSession(String id, String title) async {
    final db = await this.db;
    await db.update(
      'sessions',
      {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 设置会话级项目工作目录（空串 = 回到全局默认）。
  Future<void> setSessionWorkspace(String id, String dir) async {
    final db = await this.db;
    await db.update(
      'sessions',
      {
        'workspace_dir': dir,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 把会话移动到某个项目（projectId 为空 = 未分类）。
  Future<void> updateSessionProject(
    String id,
    String? projectId, {
    int? sortOrder,
  }) async {
    final db = await this.db;
    final updates = <String, dynamic>{
      'project_id': projectId == null || projectId.isEmpty ? null : projectId,
    };
    if (sortOrder != null) updates['sort_order'] = sortOrder;
    await db.update(
      'sessions',
      updates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 按给定 id 顺序写入项目 sort_order（下标即顺序）。
  Future<void> reorderProjects(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await this.db;
    await db.transaction((txn) async {
      for (var i = 0; i < ids.length; i++) {
        await txn.update(
          'projects',
          {'sort_order': i + 1},
          where: 'id = ?',
          whereArgs: [ids[i]],
        );
      }
    });
  }

  /// 按给定 id 顺序写入会话 sort_order（下标即顺序）。
  Future<void> reorderSessions(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await this.db;
    await db.transaction((txn) async {
      for (var i = 0; i < ids.length; i++) {
        await txn.update(
          'sessions',
          {'sort_order': i + 1},
          where: 'id = ?',
          whereArgs: [ids[i]],
        );
      }
    });
  }

  // ---- projects ----
  Future<List<Project>> listProjects() async {
    final db = await this.db;
    final rows = await db.rawQuery('''
      SELECT p.*,
             (SELECT COUNT(*) FROM sessions s WHERE s.project_id = p.id) AS session_count
      FROM projects p
      ORDER BY p.sort_order ASC, p.created_at ASC
    ''');
    return rows.map(Project.fromMap).toList();
  }

  Future<void> upsertProject(Project p) async {
    final db = await this.db;
    await db.insert(
      'projects',
      p.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> renameProject(String id, String name) async {
    final db = await this.db;
    await db.update(
      'projects',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 设置项目级工作目录（空串 = 项目下会话回到全局默认）。
  Future<void> setProjectWorkspace(String id, String dir) async {
    final db = await this.db;
    await db.update(
      'projects',
      {'workspace_dir': dir},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除项目但保留会话：项目下会话回到「未分类」。
  Future<void> deleteProject(String id) async {
    final db = await this.db;
    // 两步写放同一事务：中途失败不留半删状态。
    await db.transaction((txn) async {
      await txn.update(
        'sessions',
        {'project_id': null},
        where: 'project_id = ?',
        whereArgs: [id],
      );
      await txn.delete('projects', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> deleteSession(String id) async {
    final db = await this.db;
    // 三步删放同一事务：中途失败不留孤儿 tool_events / 半删会话。
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete('tool_events', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 按标题、消息内容或会话 ID 搜索会话，返回每个会话及一段命中内容片段。
  Future<List<SessionSearchResult>> searchSessions(String query) async {
    final db = await this.db;
    final like = '%$query%';
    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT s.*,
             (SELECT COUNT(*) FROM messages m2 WHERE m2.session_id = s.id) AS message_count
      FROM sessions s
      LEFT JOIN messages m ON m.session_id = s.id
      WHERE s.id = ? OR s.id LIKE ? OR s.title LIKE ? OR m.content LIKE ?
      ORDER BY s.updated_at DESC
    ''',
      [query, like, like, like],
    );
    final out = <SessionSearchResult>[];
    for (final r in rows) {
      final s = Session.fromMap(r);
      var snippet = '';
      final ms = await db.query(
        'messages',
        where: 'session_id = ? AND content LIKE ?',
        whereArgs: [s.id, like],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (ms.isNotEmpty) {
        final content = (ms.first['content'] as String? ?? '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
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
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> insertMessage(ChatMessage m) async {
    final db = await this.db;
    await db.insert(
      'messages',
      m.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateMessageContent(
    String id,
    String content, {
    String? reasoning,
    String? subagentResult,
    List<ToolCall>? toolCalls,
  }) async {
    final db = await this.db;
    final upd = <String, dynamic>{'content': content};
    if (reasoning != null) {
      upd['reasoning'] = reasoning;
    }
    if (subagentResult != null) {
      upd['subagent_result'] = subagentResult;
    }
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
  Future<int> addMemory(
    String content,
    String source, {
    String type = 'user',
  }) async {
    final db = await this.db;
    return db.insert('memories', {
      'content': content,
      'source': source,
      'type': type,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMemory(int id) async {
    final db = await this.db;
    await db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<MemoryEntry>> listMemories() async {
    final db = await this.db;
    final rows = await db.query(
      'memories',
      orderBy: 'created_at DESC',
      limit: 200,
    );
    return rows.map(MemoryEntry.fromMap).toList();
  }

  Future<List<MemoryEntry>> searchMemories(String query, {String? type}) async {
    final db = await this.db;
    final where = type == null || type.isEmpty
        ? 'content LIKE ?'
        : 'content LIKE ? AND type = ?';
    final args = type == null || type.isEmpty
        ? <Object>['%$query%']
        : <Object>['%$query%', type];
    final rows = await db.query(
      'memories',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: 50,
    );
    return rows.map(MemoryEntry.fromMap).toList();
  }

  Future<List<MemoryEntry>> recentMemoriesWithTerms(
    List<String> terms,
    int limit,
  ) async {
    final db = await this.db;
    if (terms.isEmpty) return listMemories().then((v) => v.take(8).toList());
    final rows = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final t in terms) {
      final r = await db.query(
        'memories',
        where: 'content LIKE ?',
        whereArgs: ['%$t%'],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      for (final row in r) {
        if (seen.add(row['id'] as int)) rows.add(row);
      }
    }
    return rows.map(MemoryEntry.fromMap).toList();
  }

  // ---- skills ----
  Future<int> addSkill(Skill s) async {
    final db = await this.db;
    return db.insert('skills', {
      'name': s.name,
      'description': s.description,
      'content': s.content,
      'files': jsonEncode(s.files),
      'large_files': jsonEncode(s.largeFiles),
      'dir_path': s.dirPath,
      'created_at': s.createdAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateSkill(Skill s) async {
    final db = await this.db;
    await db.update(
      'skills',
      {
        'name': s.name,
        'description': s.description,
        'content': s.content,
        'files': jsonEncode(s.files),
        'large_files': jsonEncode(s.largeFiles),
        'dir_path': s.dirPath,
      },
      where: 'id = ?',
      whereArgs: [s.id],
    );
  }

  Future<void> deleteSkill(int id) async {
    final db = await this.db;
    await db.delete('skills', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Skill>> listSkills() async {
    final db = await this.db;
    // 运行时只筛出能安全读取的行，不再静默删除：超大行留在库里，
    // 由迁移期清理处理，避免把“导入超大技能”误当成删除理由。
    final rows = await db.query(
      'skills',
      where:
          'length(content) <= 800000 AND '
          'length(description) <= 800000 AND '
          'length(files) <= 800000 AND '
          'length(large_files) <= 800000',
      orderBy: 'created_at DESC',
    );
    return rows.map(Skill.fromMap).toList();
  }

  Future<Skill?> getSkillByName(String name) async {
    final db = await this.db;
    final rows = await db.query(
      'skills',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : Skill.fromMap(rows.first);
  }

  // ---- tool events ----
  Future<int> addToolEvent(String sessionId, ToolEvent ev) async {
    final db = await this.db;
    return db.insert('tool_events', {
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
    await db.update(
      'tool_events',
      {
        'summary': ev.summary,
        'ok': ev.ok ? 1 : 0,
        'finished_at': ev.finishedAt,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<ToolEvent>> listToolEvents(String sessionId) async {
    final db = await this.db;
    final rows = await db.query(
      'tool_events',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'started_at ASC',
    );
    return rows.map(ToolEvent.fromMap).toList();
  }

  /// 把旧消息标记为已归档：完整原文保留在本地，但不再进入请求与上下文统计。
  Future<void> markMessagesArchived(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await this.db;
    final marks = List.filled(ids.length, '?').join(',');
    await db.update(
      'messages',
      {'archived': 1},
      where: 'id IN ($marks)',
      whereArgs: ids,
    );
  }
}
