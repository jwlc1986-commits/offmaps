import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'pantalla_mapa.dart';

void main() {
  // Antes estaba en Level.ALL: cada tile generaba cientos de líneas y eso por sí solo
  // frena el mapa. Con WARNING solo salen avisos y errores. Para depurar la librería
  // cambia a Level.INFO o Level.ALL temporalmente.
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((r) {
    debugPrint('${r.level.name}|${r.loggerName}|${r.message}');
  });

  // Al alejar el zoom por debajo de 16 se retira la capa de etiquetas mientras
  // mapsforge aún tiene un trabajo pendiente, y ese trabajo termina avisando a una cola
  // ya cerrada ("A LabelJobQueue was used after being disposed"). Es un error de la
  // librería sin efecto visible; solo se ignora ese mensaje concreto, el resto se sigue
  // mostrando.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (error.toString().contains('LabelJobQueue was used after being disposed')) {
      return true;
    }
    return false;
  };

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
