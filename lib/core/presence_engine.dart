/// 活人感：按 LAAP / Hermes 官方接法注入 PSI 认知状态。
///
/// 对照 `aris_brain/psi_jspace_bridge/psi_hermes_adapter.py`：
/// 每轮 `POST /v1/cognitive_state`，把 preamble 写入动尾，cot_hint 给思考头。
/// 没有本地关键字/需求演化替身；皮层没回状态就不注入。
class PresenceEngine {
  static const needNames = [
    'competence',
    'autonomy',
    'relatedness',
    'certainty',
    'growth',
  ];

  static const _needDirectives = {
    'competence': '展示深度专业能力，提供精确信息',
    'autonomy': '保持独立思考，提供可选方案',
    'relatedness': '优先建立情感连接，表达温暖和理解',
    'certainty': '提供确切的、可验证的信息',
    'growth': '探索边界，提出创新视角',
  };

  final Map<String, double> needs;
  double valence;
  double energy;
  double arousal;
  int cognitiveCycle;
  String attentionFocus;
  String preamble;
  String cotHint;
  bool cortexConnected;

  PresenceEngine({
    Map<String, double>? needs,
    this.valence = 0,
    this.energy = 10,
    this.arousal = 0.4,
    this.cognitiveCycle = 0,
    this.attentionFocus = 'social',
    this.preamble = '',
    this.cotHint = '',
    this.cortexConnected = false,
  }) : needs = Map<String, double>.from(
         needs ?? {for (final n in needNames) n: 0.5},
       );

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

  /// 叠上 `/v1/cognitive_state`。优先用官方 preamble / cot_hint。
  bool applyRemote({
    Map<String, double>? needs,
    double? valence,
    double? energy,
    double? arousal,
    String? attentionFocus,
    int? cognitiveCycle,
    String? preamble,
    String? cotHint,
  }) {
    var applied = false;
    if (needs != null) {
      for (final n in needNames) {
        final v = needs[n];
        if (v != null) {
          this.needs[n] = _clip(v);
          applied = true;
        }
      }
    }
    if (valence != null) {
      this.valence = valence.clamp(-1.0, 1.0);
      applied = true;
    }
    if (energy != null) {
      this.energy = energy.clamp(2.0, 10.0);
      applied = true;
    }
    if (arousal != null) {
      this.arousal = arousal.clamp(0.0, 1.0);
      applied = true;
    }
    if (attentionFocus != null && attentionFocus.trim().isNotEmpty) {
      this.attentionFocus = attentionFocus.trim();
      applied = true;
    }
    if (cognitiveCycle != null && cognitiveCycle > this.cognitiveCycle) {
      this.cognitiveCycle = cognitiveCycle;
      applied = true;
    }
    if (preamble != null && preamble.trim().isNotEmpty) {
      this.preamble = preamble.trim();
      applied = true;
    }
    if (cotHint != null && cotHint.trim().isNotEmpty) {
      this.cotHint = cotHint.trim();
      applied = true;
    }
    if (applied) {
      if (this.preamble.isEmpty) this.preamble = _fallbackPreamble();
      if (this.cotHint.isEmpty) this.cotHint = _fallbackCotHint();
    }
    cortexConnected = applied && this.preamble.isNotEmpty;
    return cortexConnected;
  }

  /// Hermes 官方 volatile 段：`PSI_SYSTEM_PROMPT_TEMPLATE` 去掉 base_prompt。
  String promptSection() {
    if (!cortexConnected || preamble.trim().isEmpty) return '';
    final d = dominantNeed;
    return '## PSI Cognitive State (Live)\n'
        '\n'
        '$preamble\n'
        '\n'
        '你的认知状态决定了你有意识的思考方向。当前最高需求 ($d) 应当影响你的回应风格：\n'
        '- 如果最高需求是 "relatedness" → 优先建立情感连接，表达温暖和理解\n'
        '- "competence" → 展示深度专业能力，提供精确信息\n'
        '- "growth" → 探索边界，提出创新视角\n'
        '- "certainty" → 提供确切的、可验证的信息\n'
        '- "autonomy" → 保持独立思考，提供可选方案\n'
        '\n'
        '在 Chain-of-Thought 中，首先确认你的认知状态 ($cotHint)。';
  }

  String _fallbackPreamble() {
    final mood = valence > 0.3
        ? '探索性'
        : valence > -0.3
        ? '专注'
        : '审慎';
    final energyStr = energy > 7
        ? '高能量'
        : energy > 4
        ? '中等'
        : '低能量';
    String n(String key) => (needs[key] ?? 0.5).toStringAsFixed(2);
    return '[PSI State — Cycle $cognitiveCycle]\n'
        'Needs: competence=${n("competence")}, autonomy=${n("autonomy")}, '
        'relatedness=${n("relatedness")}, certainty=${n("certainty")}, '
        'growth=${n("growth")}\n'
        'Dominant need: $dominantNeed ($attentionFocus mode) | '
        'Mood: $mood | $energyStr';
  }

  String _fallbackCotHint() {
    final directive = _needDirectives[dominantNeed] ?? '';
    return '[认知状态] 最高需求: $dominantNeed — $directive | '
        '注意力: $attentionFocus | '
        '唤醒: ${arousal.toStringAsFixed(2)} | '
        '能量: ${energy.toStringAsFixed(1)}';
  }

  static double _clip(double v) =>
      double.parse(v.clamp(0.1, 0.9).toStringAsFixed(4));
}
