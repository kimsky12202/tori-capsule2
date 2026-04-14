import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    const Color textColor = Color(0xFF2E2B2A);
    const Color textLightColor = Color(0xFF7A756D);
    const Color pointRedColor = Color(0xFFA14040);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F1EA),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '내정보',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        centerTitle: false,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: pointRedColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
                border: Border.all(color: pointRedColor, width: 2),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.person_outline_rounded,
                size: 40,
                color: pointRedColor,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '내정보',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: textColor,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '준비 중입니다',
              style: TextStyle(color: textLightColor, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
