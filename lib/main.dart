import 'package:flutter/material.dart';

import 'src/pins/pins_page.dart';

void main() => runApp(const MedallionApp());

class MedallionApp extends StatelessWidget {
  const MedallionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tashkent Landmark Collection',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC9A227),
          brightness: Brightness.dark,
        ),
      ),
      home: const PinsPage(),
    );
  }
}
