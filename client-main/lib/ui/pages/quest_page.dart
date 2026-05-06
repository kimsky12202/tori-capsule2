import 'package:flutter/material.dart';

class _QuestData {
  final String title;
  final String description;
  final IconData icon;
  final int current;
  final int total;

  const _QuestData({
    required this.title,
    required this.description,
    required this.icon,
    required this.current,
    required this.total,
  });

  bool get isCompleted => current >= total;
  double get progress => (current / total).clamp(0.0, 1.0);
}

class QuestPage extends StatelessWidget {
  const QuestPage({super.key});

  static const _quests = [
    _QuestData(
      title: '첫 번째 캡슐',
      description: '사진을 찍어 첫 타임캡슐 핀을 남겨보세요.',
      icon: Icons.camera_alt_outlined,
      current: 0,
      total: 1,
    ),
    _QuestData(
      title: '추억 수집가',
      description: '5개의 사진 핀을 지도에 남겨보세요.',
      icon: Icons.collections_outlined,
      current: 0,
      total: 5,
    ),
    _QuestData(
      title: '탐험가',
      description: '서로 다른 3곳에 캡슐을 남겨보세요.',
      icon: Icons.explore_outlined,
      current: 0,
      total: 3,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    const Color textColor = Color(0xFF2E2B2A);
    const Color textLightColor = Color(0xFF7A756D);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F1EA),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '퀘스트',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        children: [
          const Text(
            '특별한 순간을 기록하고\n퀘스트를 완성해보세요.',
            style: TextStyle(
              color: textLightColor,
              fontSize: 14,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),
          ..._quests.map((q) => _QuestCard(quest: q)),
        ],
      ),
    );
  }
}

class _QuestCard extends StatelessWidget {
  final _QuestData quest;

  const _QuestCard({required this.quest});

  @override
  Widget build(BuildContext context) {
    const Color textColor = Color(0xFF2E2B2A);
    const Color textLightColor = Color(0xFF7A756D);
    const Color pointRedColor = Color(0xFFA14040);
    const Color cardColor = Color(0xFFFAF9F6);
    const Color borderColor = Color(0xFFE5E0D8);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: quest.isCompleted ? pointRedColor.withValues(alpha: 0.4) : borderColor,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 아이콘
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: quest.isCompleted
                    ? pointRedColor.withValues(alpha: 0.12)
                    : const Color(0xFFF0EDE8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                quest.isCompleted ? Icons.check_circle_outline : quest.icon,
                color: quest.isCompleted ? pointRedColor : textLightColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            // 텍스트 + 진행바
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          quest.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
                      Text(
                        '${quest.current}/${quest.total}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: quest.isCompleted ? pointRedColor : textLightColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    quest.description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: textLightColor,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 진행 바
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: quest.progress,
                      minHeight: 5,
                      backgroundColor: const Color(0xFFE5E0D8),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        pointRedColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
