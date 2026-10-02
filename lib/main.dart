import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'pantalla_mapa.dart';

void main() {
  // Activar el log interno de mapsforge (aquí están los errores de render)
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    debugPrint('${r.level.name}|${r.loggerName}|${r.message}');
  });
  runApp(const OffMapsApp());
}

class OffMapsApp extends StatelessWidget {
  const OffMapsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OffMaps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7A3E)),
        useMaterial3: true,
      ),
      home: const PantallaMapa(),
    );
  }
}