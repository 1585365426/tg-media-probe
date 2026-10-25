import 'package:flutter/material.dart';

import 'ui/probe_page.dart';

void main() {
  runApp(const TgMediaProbeApp());
}

class TgMediaProbeApp extends StatelessWidget {
  const TgMediaProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TG Media Probe',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2AABEE)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2AABEE),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ProbePage(),
    );
  }
}
