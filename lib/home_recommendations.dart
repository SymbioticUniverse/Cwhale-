import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'resource_radar.dart';

typedef _Topic = ({List<String> terms, List<String> prompts});

const _topics = <_Topic>[
  (
    terms: ['ai', '模型', '提示词', '自动化', '智能体'],
    prompts: [
      '第一次用 AI 办公，可以先做哪三件事？',
      '怎么选适合日常使用的 AI 模型？',
      '怎么把常用的 AI 工作流程保存下来？',
    ],
  ),
  (
    terms: ['代码', '开发', 'flutter', 'python', '编程', '开源', 'github'],
    prompts: [
      '怎样从零整理一个开源项目的 README？',
      '怎么把一个开发任务拆成可以验收的小步骤？',
      '读陌生代码库，应该从哪些文件入手？',
    ],
  ),
  (
    terms: ['文章', '写作', '文案', '邮件', '总结', '表达'],
    prompts: ['怎么把零散素材整理成一份提纲？', '如何把一封正式邮件写得清楚又自然？', '如何把一段长文压缩成三条要点？'],
  ),
  (
    terms: ['工作', '计划', '待办', '效率', '项目', '时间'],
    prompts: ['帮我设计一个简单的每周复盘模板', '如何给本周的待办事项排优先级？', '怎样把长期目标变成今天能做的第一步？'],
  ),
  (
    terms: ['学习', '课程', '阅读', '英语', '考试', '笔记'],
    prompts: ['怎样用费曼学习法理解一个新概念？', '怎么把读书笔记变成能记住的知识？', '帮我做一个每天十五分钟的学习计划'],
  ),
  (
    terms: ['游戏', 'steam', 'epic', 'gog', '限免', '福利'],
    prompts: [
      '现在有哪些可以免费领取的 PC 游戏？',
      '这周有哪些 Epic 游戏可以免费领？',
      '用资源雷达找一下 Steam 的免费领游戏活动',
    ],
  ),
  (
    terms: ['旅行', '旅游', '出行', '周末', '城市'],
    prompts: ['帮我做一份周末短途出行清单', '怎样规划轻松一点的周末旅行？', '怎么做一份两天一夜的旅行预算？'],
  ),
];

/// Scores broad topics locally. No chat excerpts are displayed as suggestions.
List<String> _rank({
  required int round,
  required List<String> context,
  required List<String> profile,
  required List<String> radar,
}) {
  final scores = <int, int>{};
  for (var i = 0; i < _topics.length; i++) {
    int count(String text) {
      final normalized = text.toLowerCase();
      return _topics[i].terms.where(normalized.contains).length;
    }

    var score = 0;
    for (var j = 0; j < context.length; j++) {
      score += count(context[j]) * (j < 3 ? 4 : 2);
    }
    for (final signal in profile) {
      score += count(signal) * 2;
    }
    scores[i] = score;
  }
  int tieBreak(int index) => ((index - round) % _topics.length);
  final ranked = scores.keys.toList()
    ..sort((a, b) {
      final score = scores[b]!.compareTo(scores[a]!);
      return score == 0 ? tieBreak(a).compareTo(tieBreak(b)) : score;
    });
  if (radar.isNotEmpty) ranked.remove(5);
  final items = <String>[
    for (final i in ranked.take(radar.isEmpty ? 3 : 2))
      _topics[i].prompts[(round + i) % _topics[i].prompts.length],
    if (radar.isNotEmpty) radar[round % radar.length],
  ];
  return items;
}

class HomeRecommendations extends StatefulWidget {
  const HomeRecommendations({
    super.key,
    required this.context,
    required this.profile,
    required this.onSelect,
    required this.onOpenSettings,
    required this.hasModelKey,
  });

  final List<String> context;
  final List<String> profile;
  final ValueChanged<String> onSelect;
  final VoidCallback onOpenSettings;
  final bool hasModelKey;

  @override
  State<HomeRecommendations> createState() => _HomeRecommendationsState();
}

class _HomeRecommendationsState extends State<HomeRecommendations>
    with WidgetsBindingObserver {
  static int _nextRound = DateTime.now().millisecondsSinceEpoch;
  late int _round = _nextRound++;
  List<String> _radar = const [];
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRadar();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _rotate();
  }

  void _rotate() {
    setState(() {
      _round = _nextRound++;
      _radar = const [];
    });
    _loadRadar();
  }

  Future<void> _loadRadar() async {
    final id = ++_requestId;
    final prompts = await ResourceRadar.instance.recommendedPrompts();
    if (mounted && id == _requestId) setState(() => _radar = prompts);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _rank(
      round: _round,
      context: widget.context,
      profile: widget.profile,
      radar: _radar,
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '试着问',
                    style: TextStyle(color: CwhaleTheme.muted, fontSize: 12),
                  ),
                  IconButton(
                    tooltip: '换一组推荐',
                    visualDensity: VisualDensity.compact,
                    onPressed: _rotate,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                  ),
                  const Spacer(),
                  if (!widget.hasModelKey)
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text('配置模型'),
                    ),
                ],
              ),
              for (final suggestion in suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: ActionChip(
                    label: Text(
                      suggestion,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    avatar: Icon(
                      Icons.north_east_rounded,
                      size: 14,
                      color: CwhaleTheme.accent,
                    ),
                    onPressed: () => widget.onSelect(suggestion),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: CwhaleTheme.line),
                    shape: const StadiumBorder(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
