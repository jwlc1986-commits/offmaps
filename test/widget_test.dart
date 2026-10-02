// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:offmaps/estado_mapa.dart';

void main() {
  test('haversineKm devuelve distancia aproximada Bogotá-Medellín', () {
    final km = haversineKm(4.7110, -74.0721, 6.2442, -75.5812);
    expect(km, greaterThan(230));
    expect(km, lessThan(250));
  });

  test('EstadoMapa limpia puntos y trazo', () {
    final estado = EstadoMapa();
    estado.agregarPunto(4.6, -74.0);
    estado.agregarPunto(4.7, -74.1);

    expect(estado.puntos.length, 2);
    estado.limpiar();
    expect(estado.puntos, isEmpty);
    expect(estado.trazo, isEmpty);
  });
}
