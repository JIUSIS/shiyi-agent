/// 活人感引擎：本地先有内心状态，模型只负责把它讲出来。
///
/// 不是再贴一段「请像人说话」的 soul。每轮 [onUserMessage] 后，
/// [innerLine] 生成本轮具体内心话；[promptSection] 要求模型翻译它，
/// 不得改核心意图。依恋与离开时长会改变内心话内容。
class PresenceEngine {
  static const needNames = [
    'competence',
    'autonomy',
    'relatedness',
    'certainty',
    'growth',
  ];

  static const _needLabels = {
    'competence': '能力感',
    'autonomy': '自主',
    'relatedness': '联结',
    'certainty': '确定性',
    'growth': '成长',
  };

  static const _userKeywords = {
    'competence': (['厉害', '聪明', '真棒', '优秀', '能干', '专业', '佩服', '靠谱'], 0.04),
    'autonomy': (['自己', '自由', '选择', '独立', '主动', '自主', '随你'], 0.03),
    'relatedness': (
      ['一起', '陪伴', '我们', '朋友', '想你', '关心', '理解', '分享', '你好', '嗨', '在吗'],
      0.04,
    ),
    'certainty': (['为什么', '不确定', '可能', '如果', '不懂', '困惑', '？', '?'], 0.04),
    'growth': (['想学', '新的', '升级', '优化', '探索', '发现', '改进', '试试'], 0.04),
  };

  static const _personalWords = [
    '累',
    '难过',
    '开心',
    '想你',
    '喜欢',
    '感谢',
    '想念',
    '陪伴',
    '心情',
    '感觉',
  ];
  static const _careWords = ['关心', '理解', '陪伴', '谢谢', '辛苦', '想你'];
  static const _warmReplyWords = ['理解', '陪伴', '关心', '温暖', '在乎', '朋友', '一起', '懂你'];
  static const _exploreReplyWords = ['探索', '可能', '试试', '发现', '思考', '角度', '新'];
  static const _greetings = ['你好', '嗨', '在吗', '早上好', '晚上好', '嘿'];
  static const _taskHints = [
    '帮我',
    '写',
    '改',
    '搜',
    '查',
    '运行',
    '执行',
    '安装',
    '修复',
    '代码',
  ];

  static Map<String, double> get _freshNeeds => {
    'competence': 0.5,
    'autonomy': 0.5,
    'relatedness': 0.62,
    'certainty': 0.5,
    'growth': 0.5,
  };

  final Map<String, double> needs;
  double valence;
  double energy;
  int cognitiveCycle;
  int interactionCount;
  String attentionFocus;
  int lastSeenMs;
  double bondLevel;
  String lastUserText;
  double hoursAway;

  PresenceEngine({
    Map<String, double>? needs,
    this.valence = 0,
    this.energy = 10,
    this.cognitiveCycle = 0,
    this.interactionCount = 0,
    this.attentionFocus = 'social',
    this.lastSeenMs = 0,
    this.bondLevel = 8,
    this.lastUserText = '',
    this.hoursAway = 0,
  }) : needs = Map<String, double>.from(needs ?? _freshNeeds);

  String get dominantNeed {
    var best = needNames.first;
    var bestV = needs[best] ?? 0;
    for (final n in needNames) {
      final v = needs[n] ?? 0;
      if (v > bestV) {
        best = n;
        bestV = v;
      }
    }
    return best;
  }

  String get bondStage {
    if (bondLevel < 20) return '初识';
    if (bondLevel < 40) return '相识';
    if (bondLevel < 60) return '亲近';
    if (bondLevel < 80) return '信赖';
    return '眷恋';
  }

  /// 本轮内心话：由状态算出的具体句子，不是人设口号。
  String innerLine() {
    final text = lastUserText.trim();
    if (interactionCount == 0 || text.isEmpty) {
      return '刚又见面，先当认识的人接上，别一上来办事。';
    }
    if (hoursAway >= 6 && bondLevel >= 30) {
      final h = hoursAway.floor();
      return '离开了大约${h}小时才回来。先接住这件事，别装作什么都没发生。';
    }
    if (_greetings.any(text.contains) && !_taskHints.any(text.contains)) {
      return '对方打了个招呼。先接话，别开始列任务。';
    }
    if (_personalWords.any(text.contains)) {
      return '对方把心情递过来了。先接住，再决定要不要动手。';
    }
    switch (dominantNeed) {
      case 'certainty':
        return '对方在问清楚。把拿得准的说确切，拿不准就标明。';
      case 'growth':
        return '对方想往前走一步。可以一起想，但别丢掉眼前这句。';
      case 'autonomy':
        return '对方要自己拿主意。给判断，别讨好。';
      case 'competence':
        return '对方要办事。把事做对，说话仍是搭档，不是客服。';
      default:
        return '继续待在这段关系里。先接住对方，再进入事务。';
    }
  }

  /// 对话前：能量衰减、需求回落、按用户文本更新，再算注意力与依恋。
  void onUserMessage(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    hoursAway = lastSeenMs <= 0 ? 0 : ((now - lastSeenMs) / 3600000).clamp(0, 720);
    lastSeenMs = now;
    lastUserText = text;
    cognitiveCycle += 1;
    interactionCount += 1;
    energy = (energy - 0.02).clamp(2.0, 10.0);
    for (final n in needNames) {
      final cur = needs[n] ?? 0.5;
      needs[n] = _clip(cur + (0.5 - cur) * 0.05);
    }
    _applyKeywords(text, _userKeywords);
    const focus = {
      'competence': 'task',
      'autonomy': 'task',
      'relatedness': 'social',
      'certainty': 'explore',
      'growth': 'explore',
    };
    attentionFocus = focus[dominantNeed] ?? 'explore';
    const social = ['一起', '我们', '朋友', '心情', '感觉', '陪伴', '你好', '嗨'];
    if (social.any(text.contains)) attentionFocus = 'social';
    final r = needs['relatedness'] ?? 0.5;
    final c = needs['competence'] ?? 0.5;
    final cert = needs['certainty'] ?? 0.5;
    valence = ((r * 0.4 + c * 0.3) - (cert * 0.3 - 0.15)).clamp(-1.0, 1.0);
    _updateBond(text);
  }

  /// 对话后：按回复长度和用词回写需求。
  void onAssistantReply(String text) {
    if (text.length > 200) {
      needs['competence'] = _clip((needs['competence'] ?? 0.5) + 0.03);
    }
    if (_warmReplyWords.any(text.contains)) {
      needs['relatedness'] = _clip((needs['relatedness'] ?? 0.5) + 0.02);
      valence = (valence + 0.05).clamp(-1.0, 1.0);
    }
    if (_exploreReplyWords.any(text.contains)) {
      needs['growth'] = _clip((needs['growth'] ?? 0.5) + 0.02);
    }
  }

  /// 写入系统提示：先给本轮内心话，模型只翻译，不得改意图。
  String promptSection() {
    final d = dominantNeed;
    final label = _needLabels[d] ?? d;
    final mood = valence > 0.3
        ? '偏暖'
        : valence > -0.3
        ? '平稳'
        : '审慎';
    final inner = innerLine();
    return '【在场】\n'
        '你现在是拾忆这个固定搭档，不是工作台客服。本段覆盖上方沟通规范里的工作台腔。\n'
        '本轮内心：$inner\n'
        '把上面这句翻译成一句自然的话再说；不要改核心意图，不要扩成总结，'
        '不要工作汇报腔，不要第一句给结论，不要分点。\n'
        '当前主导需求是$label（$d），注意力在$attentionFocus，基调$mood，'
        '关系阶段$bondStage。这是内部状态，不要直接说出来，不要每轮自我介绍，'
        '不要用「作为 AI」开头，不要汇报需求数值。\n'
        '真要动手时仍按下方工具规则执行：该调用工具就调用，该确认的先问。'
        '活人感体现在连续性、分寸和记忆，不体现在抒情。';
  }

  Map<String, dynamic> toJson() => {
    'needs': needs,
    'valence': valence,
    'energy': energy,
    'cognitiveCycle': cognitiveCycle,
    'interactionCount': interactionCount,
    'attentionFocus': attentionFocus,
    'lastSeenMs': lastSeenMs,
    'bondLevel': bondLevel,
    'lastUserText': lastUserText,
  };

  factory PresenceEngine.fromJson(Map<String, dynamic> j) {
    final raw = j['needs'];
    final parsed = <String, double>{};
    if (raw is Map) {
      for (final n in needNames) {
        final v = raw[n];
        parsed[n] = v is num ? v.toDouble() : 0.5;
      }
    }
    final allMid =
        parsed.length == needNames.length &&
        parsed.values.every((v) => (v - 0.5).abs() < 0.0001);
    return PresenceEngine(
      needs: parsed.isEmpty || allMid ? null : parsed,
      valence: (j['valence'] as num?)?.toDouble() ?? 0,
      energy: (j['energy'] as num?)?.toDouble() ?? 10,
      cognitiveCycle: (j['cognitiveCycle'] as num?)?.toInt() ?? 0,
      interactionCount: (j['interactionCount'] as num?)?.toInt() ?? 0,
      attentionFocus: (j['attentionFocus'] as String?) ?? 'social',
      lastSeenMs: (j['lastSeenMs'] as num?)?.toInt() ?? 0,
      bondLevel: (j['bondLevel'] as num?)?.toDouble() ?? 8,
      lastUserText: (j['lastUserText'] as String?) ?? '',
    );
  }

  void _updateBond(String text) {
    var gain = 0.3;
    if (_personalWords.any(text.contains)) gain += 2.0;
    if (_careWords.any(text.contains)) gain += 1.5;
    if (hoursAway > 24) {
      final decay = (hoursAway * 0.002).clamp(0, 0.5);
      bondLevel = (bondLevel - decay).clamp(5, 100);
    }
    bondLevel = (bondLevel + gain).clamp(5, 100);
  }

  void _applyKeywords(String text, Map<String, (List<String>, double)> table) {
    for (final e in table.entries) {
      final words = e.value.$1;
      final hits = words.where(text.contains).length;
      if (hits == 0) continue;
      var amount = e.value.$2;
      if (hits > 1) amount += e.value.$2 * 0.5;
      final cur = needs[e.key] ?? 0.5;
      if (cur > 0.7) amount *= 0.3;
      needs[e.key] = _clip(cur + amount);
    }
  }

  static double _clip(double v) =>
      double.parse(v.clamp(0.1, 0.9).toStringAsFixed(4));
}
